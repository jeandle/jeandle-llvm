//===- JavaType.h - Java Type Query Interface -----------------------------===//
//
// Copyright (c) 2025, the Jeandle-LLVM Authors. All Rights Reserved.
//
// Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM
// Exceptions. See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//
//
// Provides interfaces to query Java type information from LLVM IR.
// Type information is encoded in attributes ("java-klass", "java-klass-exact")
// and metadata (!java-klass). This interface can be used by any Jeandle pass
// that needs compile-time type information.
//
//===----------------------------------------------------------------------===//

#ifndef JEANDLE_JAVA_TYPE_H
#define JEANDLE_JAVA_TYPE_H

#include "llvm/ADT/DenseSet.h"
#include "llvm/ADT/STLFunctionalExtras.h"

#include <cstdint>

namespace llvm {

class BasicBlock;
class DominatorTree;
class Instruction;
class Value;

namespace jeandle {

/// Represents the Java type of an LLVM IR value, including both positive
/// type knowledge and negative constraints (excluded classes).
///
/// JavaType does not encode nullability. A known Klass describes the Java
/// class of the referenced object when the queried value is known to denote a
/// non-null oop.
struct JavaType {
  /// The Klass pointer (from HotSpot JVM). 0 means unknown.
  uintptr_t Klass = 0;

  SmallDenseSet<uintptr_t, 2> Interfaces;

  /// If true, the value is exactly this class, not a subclass.
  bool Exact = false;

  /// Klasses this value is known NOT to be an instance of.
  /// Populated from failed type checks (type-denied branch outcomes) met
  /// along the CFG paths that reach the query point and joined at merges —
  /// the denying check need not dominate the query point. Only the most
  /// general (uppermost) excluded classes are stored; more specific subtypes
  /// are implied.
  SmallDenseSet<uintptr_t, 2> ExcludedKlasses;
  JavaType() = default;
  JavaType(uintptr_t Klass, bool Exact);
  bool isUnknown() const {
    return Klass == 0 && Interfaces.empty() && ExcludedKlasses.empty();
  }
  bool isKnown() const { return Klass != 0; }
  bool hasExclusions() const { return !ExcludedKlasses.empty(); }

  bool operator==(const JavaType &Other) const {
    return Klass == Other.Klass && Exact == Other.Exact &&
           ExcludedKlasses == Other.ExcludedKlasses &&
           Interfaces == Other.Interfaces;
  }

  bool operator!=(const JavaType &Other) const { return !(*this == Other); }
};

/// Oracle answering "is V provably null on the CFG edge FromBB->ToBB?".
/// Edge-semantics sharpening skips proven-null edges: JavaType is conditioned
/// on a non-null oop (see struct JavaType above), and a null-proven edge
/// carries no non-null type constraint. Only positive proof may return true;
/// when in doubt, return false (keeping the edge is always sound).
/// The standard implementation is LVINullEdgeOracle (LazyValueInfo-backed);
/// it recognizes null tests both directly on the edge's branch and through
/// threaded/indirect forms. Context-sensitive callers must supply one; a null
/// oracle is only meaningful for context-insensitive (base-only) queries,
/// where the engine is not run at all.
using IsNullEdgeOracle =
    function_ref<bool(Value *V, BasicBlock *FromBB, BasicBlock *ToBB)>;

/// Get the Java type of a value.
///
/// When Context is null, performs a context-insensitive query using only
/// attributes and metadata attached to the value (and PHI incoming values).
///
/// When Context is provided, additionally performs context-sensitive sharpening
/// with the edge-semantics dataflow engine: guards attached to CFG edges are
/// met along paths and joined at merges, giving the type constraints that hold
/// for V at the context instruction. Proven-null edges and back edges are
/// excluded; both exclusions are exact under the non-null contract (see the
/// design comment in JavaType.cpp). Null-edge proofs come from the supplied
/// oracle.
///
/// JavaType does not model nullability. Sharpening derived from
/// jeandle.check_instanceof is therefore only sound for consumers whose IR/API
/// contract guarantees that the queried oop is non-null at the check site
/// (e.g. check_instanceof's nonnull parameter, or an explicit non-null proof
/// as in ConstantFieldFolding). Edges on which the value is provably null are
/// excluded from the analysis via the supplied oracle — including individual
/// PHI incoming arms — so a PHI whose remaining arms agree on a klass can
/// come back Known even though the value can be null on the skipped arm.
/// Consumers that materialize the result as IR facts (metadata, assumes) must
/// themselves ensure the value is non-null at the point of use, as the IR
/// semantics of that use (a field load's implicit null check, a virtual
/// call's receiver dispatch) normally do.
///
/// The query traces through a limited set of IR patterns:
/// - PHI nodes (with cycle detection for loop back-edges)
/// - Select instructions (constant and non-constant arms)
/// - Integer casts: zext, sext, trunc (but not bitcast, fpcast, etc.)
/// - ICmp comparisons of a check_instanceof result against a constant
/// - Direct jeandle.check_exact_klass calls
/// - And (i1) of two traced conditions
/// - Or (i1) of two traced conditions
/// - Xor i1 %a, true: logical NOT
/// - Direct jeandle.check_instanceof calls
/// Unrecognized patterns conservatively return unknown ({}).
JavaType getJavaType(Value *V, DominatorTree *DT, Instruction *Context,
                     IsNullEdgeOracle IsNullEdge);

/// Compute the type constraints that CFG edge guards imply for V at Context.
/// Returns ONLY check-derived constraints (a positive klass when a passing
/// check proves it, with Exact set from IsEffectivelyFinal, plus excluded
/// klasses from failed checks) — never attribute/metadata-derived base types.
///
/// DestBB must be the PHI's parent block and Context the terminator of the
/// PHI incoming block: the guard on the edge Context->parent -> DestBB is
/// also considered, because a PHI incoming use is edge-local — if exactly one
/// successor is DestBB, that outcome's constraints apply to the value flowing
/// along that edge.
///
/// The result depends only on the CFG, branch conditions, the null-edge
/// oracle and VM callbacks; it is constant while those are unchanged. Sound
/// under the same non-null oop contract as getJavaType.
JavaType sharpen(Value *V, Instruction *Context, DominatorTree &DT,
                 BasicBlock *DestBB, IsNullEdgeOracle IsNullEdge);

/// Compute the type union of two Java types. Used when the value could be
/// either type (PHI, select). Widens positive type to LCA and intersects
/// ExcludedKlasses (only exclusions common to both survive).
JavaType typeUnion(JavaType A, JavaType B);

/// Compute the type intersection of two Java types. Used when both constraints
/// apply simultaneously to the same value (base type + sharpened type).
/// Narrows to the more specific positive type and unions ExcludedKlasses.
JavaType typeIntersect(JavaType A, JavaType B);

/// Returns true if Klass and OtherKlass are provably incompatible under
/// Java's single-class inheritance. Requires VM callbacks to be registered.
/// \p KlassExact indicates whether Klass is known to be an exact type.
bool areKlassesIncompatible(uintptr_t Klass, bool KlassExact,
                            uintptr_t OtherKlass);

/// Extract a Klass pointer constant from a Value.
/// Strips pointer casts and aliases first, then handles: freeze passthrough,
/// inttoptr of ConstantInt (instruction and ConstantExpr forms),
/// inttoptr(zext/sext(V)) widening casts, inttoptr(ptrtoint(V)) round-trip
/// chains, load from a constant GlobalVariable (recurses into initializer,
/// follows GlobalAlias), and bare ConstantInt (reachable via GlobalVariable
/// recursion). Has a recursion depth limit to prevent infinite recursion.
/// Returns 0 if the value does not encode a constant klass pointer.
uintptr_t extractKlassConstant(Value *V);

} // namespace jeandle
} // namespace llvm

#endif // JEANDLE_JAVA_TYPE_H
