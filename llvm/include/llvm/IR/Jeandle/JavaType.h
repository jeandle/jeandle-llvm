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
  /// Populated from dominating failed type checks (type-denied paths).
  /// Only the most general (uppermost) excluded classes are stored;
  /// more specific subtypes are implied.
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

/// Get the Java type of a value.
///
/// When Context is null, performs a context-insensitive query using only
/// attributes and metadata attached to the value (and PHI incoming values).
///
/// When Context is provided, additionally performs context-sensitive sharpening
/// by examining dominating type guards that constrain the value's type at the
/// point of the context instruction.
///
/// JavaType does not model nullability. Sharpening derived from
/// jeandle.check_instanceof is therefore only sound for consumers whose IR/API
/// contract guarantees that the queried oop is non-null at the check site.
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
JavaType getJavaType(Value *V, DominatorTree *DT = nullptr,
                     Instruction *Context = nullptr);

/// Compute the type constraints that dominating jeandle.check_instanceof
/// checks imply for V at Context. Returns ONLY check-derived constraints (a
/// positive klass when a passing check proves it, with Exact set from
/// IsEffectivelyFinal, plus excluded klasses from failed checks) — never
/// attribute/metadata-derived base types.
///
/// When DestBB is non-null, Context must be the terminator of a PHI incoming
/// block and DestBB the PHI's parent block; the incoming block's own
/// conditional branch is then considered: a PHI incoming use is edge-local,
/// so if exactly one successor is DestBB, that outcome's constraints apply to
/// the value flowing along that edge. When DestBB is null, Context's own
/// branch is not considered.
///
/// The result depends only on the CFG, branch conditions and VM callbacks; it
/// is constant while those are unchanged. Sound under the same non-null oop
/// contract as getJavaType.
JavaType sharpenFromDominators(Value *V, Instruction *Context,
                               DominatorTree &DT, BasicBlock *DestBB = nullptr);

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
