//===- PartialEscapeUtils.h - PEA helpers -----------------------*- C++ -*-===//
//
// Copyright (c) 2026, the Jeandle-LLVM Authors. All Rights Reserved.
//
// Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM
// Exceptions. See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//
//
// Pure helpers used by both the analysis and the transform pass.  No state.
//
//===----------------------------------------------------------------------===//

#ifndef LLVM_ANALYSIS_JEANDLE_PARTIALESCAPEUTILS_H
#define LLVM_ANALYSIS_JEANDLE_PARTIALESCAPEUTILS_H

#include "llvm/ADT/ArrayRef.h"
#include "llvm/ADT/STLFunctionalExtras.h"
#include "llvm/ADT/SmallVector.h"
#include "llvm/ADT/StringRef.h"
#include "llvm/Analysis/Jeandle/PartialEscape.h"
#include "llvm/IR/Jeandle/Deoptimization.h"
#include "llvm/IR/Jeandle/VMConstants.h"
#include "llvm/IR/Value.h"
#include "llvm/IR/ValueHandle.h"
#include <cstdint>
#include <optional>

namespace llvm {
class CallBase;
class DataLayout;
class Function;
class GetElementPtrInst;
class Instruction;
class IntrinsicInst;
class LLVMContext;
class Type;
} // namespace llvm

namespace llvm::jeandle::pea {

// A checked, assertion-free view of a DeoptValueEncoding. Index remains
// signed because descriptor IDs and field offsets have different semantic
// validity rules.
struct CheckedDeoptValueEncoding {
  // Index field (bits [63:32] of the raw encoding): a frame slot number, a
  // descriptor wire ID, or a field offset, per the enclosing record.
  int32_t Index = 0;
  // Value-type field (bits [31:16]): which grammar record the value belongs
  // to (local, stack, monitor, VO reference, marker, ...).
  DeoptValueEncoding::DeoptValueType ValueType = DeoptValueEncoding::LocalType;
  // Basic-type field (bits [15:0]): the HotSpot basic type of the value.
  HotspotBasicType BasicType = T_ILLEGAL;

  bool operator==(const CheckedDeoptValueEncoding &Other) const {
    return Index == Other.Index && ValueType == Other.ValueType &&
           BasicType == Other.BasicType;
  }
};

// Decode one i64 deopt-value encoding constant into its checked,
// assertion-free form. Returns std::nullopt for non-constant or non-i64
// values and for out-of-range value/basic types.
std::optional<CheckedDeoptValueEncoding>
decodeDeoptValueEncoding(const Value *V);

// Grammar role of one operand position ("cell") within a "deopt" operand
// bundle. A cell identifies exactly one bundle input, so edits and audits
// can refer back to exact operands without re-parsing. The roles mirror the
// bundle grammar: scope preamble, VO descriptor pool records, scope-value
// records, monitor records, the original-PC marker, inlinee method markers,
// and the narrow-oop tail.
enum class DeoptSemanticCellRole : uint8_t {
  // Scope preamble.
  ShouldReexecute, // i64 should_reexecute slot preceding the BCI pair.
  BCI,             // One operand of the duplicated equal-i32 BCI pair.
  // VO descriptor pool records (root scope only).
  DescriptorHeader,        // Descriptor header encoding (index = wire ID).
  DescriptorKlass,         // i64 klass pointer of a descriptor.
  DescriptorFieldCount,    // i32 field count of a descriptor.
  DescriptorFieldEncoding, // Encoding operand of one descriptor field.
  DescriptorFieldValue,    // Value operand of one descriptor field (scalar,
                           // or wire ID for a VORef field).
  // Scope-value records (locals and expression stack).
  ScopeValueEncoding, // Encoding operand of a local/stack slot.
  ScopeValue,         // Value operand of a local/stack slot (scalar, or
                      // wire ID for a VORef slot).
  // Monitor records.
  MonitorEncoding, // Encoding operand of a monitor record.
  MonitorOwner,    // Owner operand (wide oop, or wire ID when eliminated).
  MonitorLock,     // Lock-slot operand (addrspace(0) pointer).
  // Original-PC marker (root scope only).
  OrigPcEncoding, // Encoding operand of the original-PC marker.
  OrigPcValue,    // PC operand (addrspace(0) pointer).
  // Inlinee method marker (non-root scopes).
  MethodEncoding, // Encoding operand of a method marker.
  MethodValue,    // MethodType pointer operand, as i64.
  // Narrow-oop tail records.
  NarrowOopEncoding, // Encoding operand of a narrow-oop tail record.
  NarrowOopValue     // Narrow-oop operand (NarrowOopAddrSpace pointer).
};

// A semantic cell: one operand position in a "deopt" bundle's input list,
// tagged with the grammar role the parser assigned to it. Bundle edits and
// audits refer back to exact operands through these cells.
struct DeoptSemanticCell {
  // Grammar role of the operand at OperandIndex.
  DeoptSemanticCellRole Role = DeoptSemanticCellRole::ScopeValue;
  // Index into the bundle's input list.
  unsigned OperandIndex = 0;
};

// Exact structural data used to detect a stale bundle before transform. Values
// which carry program state contribute their LLVM type but not their SSA
// identity; grammar constants additionally contribute their exact bit value.
struct DeoptStructuralCell {
  // Grammar role and input position of the operand, as recorded at parse
  // time.
  DeoptSemanticCellRole Role = DeoptSemanticCellRole::ScopeValue;
  unsigned OperandIndex = 0;
  // LLVM type of the operand at parse time; a type change means the bundle
  // was edited.
  Type *OperandType = nullptr;
  // Exact constant bits for grammar-constant cells; std::nullopt for
  // semantic-value cells, whose SSA value may follow legitimate RAUW.
  std::optional<uint64_t> ConstantValue;

  bool operator==(const DeoptStructuralCell &Other) const {
    return Role == Other.Role && OperandIndex == Other.OperandIndex &&
           OperandType == Other.OperandType &&
           ConstantValue == Other.ConstantValue;
  }
};

// Structural fingerprint of a parsed bundle: the ordered structural cells of
// every bundle input. Together with the tracked SSA values, a fingerprint
// mismatch detects that the bundle was structurally edited since the parse.
struct DeoptBundleStructuralFingerprint {
  // One cell per bundle input, in wire order.
  SmallVector<DeoptStructuralCell, 16> Cells;

  bool operator==(const DeoptBundleStructuralFingerprint &Other) const {
    return Cells == Other.Cells;
  }
  bool operator!=(const DeoptBundleStructuralFingerprint &Other) const {
    return !(*this == Other);
  }
};

// One field of a VO descriptor: an (offset, value) pair recording what the
// object's field at Offset must hold when the object is rematerialized at
// the deopt point.
struct ParsedDeoptField {
  // Byte offset of the field within the object (the encoding's index).
  int32_t Offset = 0;
  // The field's deopt value encoding.
  CheckedDeoptValueEncoding Encoding;
  // Cells of the encoding and value operands, for bundle edits/audits.
  DeoptSemanticCell EncodingCell;
  DeoptSemanticCell ValueCell;
  // For VORefLocalType fields: wire ID of the referenced descriptor. A wire
  // ID is an index into the root scope's VO descriptor pool; a reference
  // operand carries it as an i32 constant.
  std::optional<int32_t> TargetWireID;
};

// One VO descriptor from the root scope's object pool: the klass and field
// state needed to rematerialize one virtual object at the deopt point.
struct ParsedDeoptDescriptor {
  // This descriptor's wire ID (index into the object pool), referenced by
  // VORef records elsewhere in the bundle.
  int32_t WireID = 0;
  // True for array VOs (header basic type T_ARRAY), false for instances.
  bool IsArray = false;
  // Klass pointer of the object, as a raw i64.
  uint64_t Klass = 0;
  // Cells of the header, klass, and field-count operands.
  DeoptSemanticCell HeaderCell;
  DeoptSemanticCell KlassCell;
  DeoptSemanticCell FieldCountCell;
  // Field records, in wire order.
  SmallVector<ParsedDeoptField, 4> Fields;
};

// One local or expression-stack slot of a deopt scope.
struct ParsedDeoptScopeValue {
  // Logical slot index in the locals/stack section, counting double-word
  // values as two slots.
  unsigned PhysicalSlot = 0;
  // Number of frame slots occupied: 2 for long/double, 1 otherwise.
  unsigned SlotWidth = 1;
  // The slot's deopt value encoding.
  CheckedDeoptValueEncoding Encoding;
  // Cells of the encoding and value operands.
  DeoptSemanticCell EncodingCell;
  DeoptSemanticCell ValueCell;
  // For VORef slots: wire ID of the referenced descriptor.
  std::optional<int32_t> TargetWireID;
};

// One monitor record of a deopt scope: owner object plus lock slot.
struct ParsedDeoptMonitor {
  // The monitor's deopt value encoding; index 1 marks an eliminated
  // (scalar-replaced) monitor, 0 a surviving one.
  CheckedDeoptValueEncoding Encoding;
  // True when the monitor was eliminated and its owner is a VO reference.
  bool Eliminated = false;
  // Cells of the encoding, owner, and lock operands.
  DeoptSemanticCell EncodingCell;
  DeoptSemanticCell OwnerCell;
  DeoptSemanticCell LockCell;
  // For eliminated monitors: wire ID of the owner VO's descriptor.
  std::optional<int32_t> OwnerWireID;
};

// A two-operand marker record (encoding + value): used for the root scope's
// original-PC slot and for each narrow-oop tail entry.
struct ParsedDeoptMarker {
  // The marker's deopt value encoding.
  CheckedDeoptValueEncoding Encoding;
  // Cells of the encoding and value operands.
  DeoptSemanticCell EncodingCell;
  DeoptSemanticCell ValueCell;
};

// An inlinee scope's method marker: the MethodType pointer identifying the
// inlined method.
struct ParsedDeoptMethod {
  // MethodType pointer as a raw i64.
  uint64_t Method = 0;
  // Cells of the encoding and value operands.
  DeoptSemanticCell EncodingCell;
  DeoptSemanticCell ValueCell;
};

// One parsed deopt scope (one frame): root or inlinee. The root scope may
// carry should_reexecute and the original-PC marker; an inlinee scope
// carries a method marker instead.
struct ParsedDeoptScope {
  // Inlinee scopes only: the method marker. Absent for the root scope.
  std::optional<ParsedDeoptMethod> Method;
  // The should_reexecute flag, when the scope header carries one
  // (production records; hand-written tests omit it).
  std::optional<uint64_t> ShouldReexecute;
  // Cell of the should_reexecute operand, when present.
  std::optional<DeoptSemanticCell> ShouldReexecuteCell;
  // Bytecode index of this frame (sign-extended from the duplicated i32
  // BCI pair).
  int32_t BCI = 0;
  // Cells of the duplicated BCI pair (two operands with equal values).
  DeoptSemanticCell FirstBCICell;
  DeoptSemanticCell SecondBCICell;
  // Locals, expression stack, and monitor records, in wire order.
  SmallVector<ParsedDeoptScopeValue, 8> Locals;
  SmallVector<ParsedDeoptScopeValue, 8> Stack;
  SmallVector<ParsedDeoptMonitor, 2> Monitors;
  // Root scope only: the original-PC marker.
  std::optional<ParsedDeoptMarker> OrigPc;
};

// A fully parsed "deopt" operand bundle: the VO descriptor pool, all scopes
// (root first, innermost inlinee last), the narrow-oop tail, and the
// structural fingerprint used to detect later edits.
struct ParsedDeoptBundle {
  // The parsed bundle is analysis data that may outlive ordinary effect
  // application. Tracking handles follow legitimate RAUW and become null when
  // an input is erased without replacement.
  SmallVector<WeakTrackingVH, 16> OriginalInputs;
  // VO descriptor pool (the root scope's VO section), in wire order.
  SmallVector<ParsedDeoptDescriptor, 4> Descriptors;
  // All scopes: root scope first, innermost (current-method) scope last.
  SmallVector<ParsedDeoptScope, 2> Scopes;
  // Narrow-oop tail markers, in wire order.
  SmallVector<ParsedDeoptMarker, 2> NarrowOopMarkers;
  // Structural fingerprint for staleness detection; one cell per input.
  DeoptBundleStructuralFingerprint Fingerprint;
};

// Why a bundle parse failed. Parse failures are reported as data through
// this code plus the operand index where the problem was found; the parser
// never asserts, so it is safe to run on arbitrary (even malformed) IR.
enum class DeoptBundleParseErrorCode : uint8_t {
  None,                    // No error (parse succeeded).
  MissingBundle,           // The call has no "deopt" operand bundle.
  InvalidScopeHeader,      // Missing/malformed should_reexecute or BCI pair.
  MismatchedBCI,           // The duplicated BCI values differ.
  InvalidEncoding,         // An i64 encoding constant failed to decode.
  TruncatedRecord,         // Fewer operands remain than a record requires.
  DescriptorNotInRootPool, // A VO descriptor appeared outside the root pool.
  DuplicateDescriptorID,   // Two descriptors share a wire ID.
  DuplicateFieldOffset,    // Two fields of a descriptor share an offset.
  DanglingVORef,           // A VO reference names an unknown wire ID.
  InvalidScopeOrder,       // Records out of grammar order within a scope.
  InvalidSemanticValue,    // A value operand does not match its encoding.
  InvalidMonitor,          // Malformed monitor record.
  InvalidOrigPc,           // Malformed or misplaced original-PC marker.
  InvalidMethodMarker,     // Malformed inlinee method marker.
  InvalidNarrowOopMarker   // Malformed narrow-oop tail record.
};

// A parse failure: what failed, and where.
struct DeoptBundleParseError {
  // The kind of failure.
  DeoptBundleParseErrorCode Code = DeoptBundleParseErrorCode::None;
  // Bundle input index at which the parser detected the failure.
  unsigned OperandIndex = 0;
};

// Result of parsing a "deopt" operand bundle: exactly one of Bundle (on
// success) or Error (on failure) is meaningful.
struct DeoptBundleParseResult {
  // The parsed bundle; std::nullopt on failure.
  std::optional<ParsedDeoptBundle> Bundle;
  // The failure; Code == None on success.
  DeoptBundleParseError Error;
};

// Parse the complete record grammar used by Jeandle's "deopt" operand bundle.
// Both the production header (i64 should_reexecute + duplicated i32 BCI) and
// the deliberately simplified test header (duplicated i32 BCI) are accepted.
// All failures are reported as data; this path never calls the assertion-based
// DeoptValueEncoding::decode.
DeoptBundleParseResult parseDeoptBundleInputs(ArrayRef<Value *> Inputs);
DeoptBundleParseResult parseDeoptBundle(const CallBase &CB);

// Return whether CB still has the exact bundle parsed into Bundle. Grammar
// constants must retain their exact bits; semantic values may follow RAUW via
// OriginalInputs' tracking handles.
bool matchesParsedDeoptBundle(const ParsedDeoptBundle &Bundle,
                              const CallBase &CB);

// Copy the parsed representation in its original wire order. Returns false if
// a tracked input died or its exact-cell/fingerprint indices are incoherent.
bool copyParsedDeoptBundleInputs(const ParsedDeoptBundle &Bundle,
                                 SmallVectorImpl<Value *> &Out);

// Callee-name predicates. Match a CallBase by callee Function name. Tolerates
// CallInst, InvokeInst, and any subclass of CallBase. Returns false on inline
// asm, indirect calls, or NULL Function.
bool isJeandleCallNamed(const CallBase *CB, StringRef Name);
bool isJeandleNewInstance(const CallBase *CB);
bool isJeandleNewArray(const CallBase *CB);
bool isJeandleAllocation(const CallBase *CB); // either of the above
bool isJeandleArrayLength(const CallBase *CB);
bool isJeandleLoadKlass(const CallBase *CB);
bool isJeandleGetClass(const CallBase *CB);
bool isJeandleCheckCast(const CallBase *CB);
bool isJeandleInstanceOf(const CallBase *CB);
bool isJeandleCheckInstanceOf(const CallBase *CB);
bool isJeandleCheckIfValueBased(const CallBase *CB);
bool isJeandleArrayStoreCheck(const CallBase *CB);
bool isJeandlePostBarrier(const CallBase *CB);
bool isJeandleMonitorEnter(const CallBase *CB);
bool isJeandleMonitorExit(const CallBase *CB);
bool isJeandleRegisterFinalizerIfNeeded(const CallBase *CB);

// Whether processIntrinsic treats II's ordinary operands and non-deopt operand
// bundles as non-escaping. Deopt bundles remain executable frame state and
// require a surviving whole-pool rewrite.
bool isPEAHandledNonEscapingIntrinsic(const IntrinsicInst *II);

// Map a JBasicType to its LLVM IR storage type for one element (e.g., Byte→i8,
// Object→ptr addrspace(1)).  Returns nullptr if Kind == Count.
Type *llvmElementTypeFor(JBasicType Kind, LLVMContext &Ctx);

// Whether Ty may be emitted by materialization as an LLVM atomic store.
// Mirrors Verifier::visitStoreInst/checkAtomicMemAccessSize: a sized,
// fixed-width integer, pointer, floating-point, or vector thereof whose total
// width is at least one byte and a power of two.
bool isLegalMaterializationAtomicType(Type *Ty, const DataLayout &DL);

// Checked arithmetic for the signed byte-offset model shared by pointer
// resolution, field ranges, array addressing, and deopt descriptors. An empty
// result means the value cannot be represented by int64_t and callers must
// treat the access as unknown.
std::optional<int64_t> checkedOffsetAdd(int64_t LHS, int64_t RHS);
std::optional<int64_t> checkedOffsetSub(int64_t LHS, int64_t RHS);
std::optional<int64_t> checkedArrayElementOffset(int64_t Base, int64_t Index,
                                                 uint64_t Scale);

// Field state uses DenseMap<int64_t, ...>; its empty and tombstone keys cannot
// represent real offsets. Such offsets are unknown to PEA.
bool isUsableFieldOffset(int64_t Offset);

// Return whether the half-open ranges overlap. An empty result means at least
// one endpoint is not representable; it is not proof of non-overlap.
std::optional<bool> checkedRangesOverlap(int64_t AStart, uint64_t ASize,
                                         int64_t BStart, uint64_t BSize);

// Strip pointer-identity-preserving operations (bitcast, addrspacecast
// within addrspace(1), freeze, launder/strip.invariant.group, ptr.annotation,
// and a pre-existing same-width inttoptr(ptrtoint(x)) round-trip) and
// constant-offset GEPs, accumulating the constant offset into *OutOffset.
// Returns the root pointer. Sets *Unresolved = true if a non-constant GEP
// index, a non-representable APInt, or an overflowing accumulated offset was
// encountered (then the accumulated offset is invalid). Instruction dispatch
// treats PtrToIntInst as an identity observation regardless; structural
// round-trip peeling does not keep a virtual object alive across it. Shared
// structural helper used by resolveVirtualRef and resolveFieldOffset.
Value *stripPointerCastsAndOffsets(Value *Ptr, const DataLayout &DL,
                                   int64_t *OutOffset, bool *Unresolved);

// Result of resolving the virtual-object identity carried by an LLVM value.
// Poison is a refinement wildcard while resolving a PHI/select, but is never
// itself a defined identity. Undef and all other unresolved values are
// Unknown.
class VirtualIdentityResult {
public:
  enum class Kind : uint8_t { DefinedIdentity, PoisonWildcard, Unknown };

  static VirtualIdentityResult defined(ObjectID ID) {
    assert(ID != InvalidObjectID);
    return VirtualIdentityResult(Kind::DefinedIdentity, ID);
  }
  static VirtualIdentityResult poisonWildcard() {
    return VirtualIdentityResult(Kind::PoisonWildcard, InvalidObjectID);
  }
  static VirtualIdentityResult unknown() {
    return VirtualIdentityResult(Kind::Unknown, InvalidObjectID);
  }

  Kind getKind() const { return K; }
  bool isDefined() const { return K == Kind::DefinedIdentity; }
  bool isPoisonWildcard() const { return K == Kind::PoisonWildcard; }
  ObjectID getObjectID() const {
    assert(isDefined());
    return ID;
  }

private:
  VirtualIdentityResult(Kind K, ObjectID ID) : K(K), ID(ID) {}

  Kind K;      // Which outcome this result represents.
  ObjectID ID; // Resolved object; valid only for DefinedIdentity.
};

enum class VirtualIdentityMode : uint8_t {
  // Resolve the underlying virtual object. Constant-offset derived pointers
  // keep the base identity.
  BaseObject,
  // Resolve only values that denote the complete object at byte offset zero
  // on every defined path.
  WholeObject
};

// Resolve V using the shared DefinedIdentity/PoisonWildcard/Unknown model.
// Cycle-safe via a small visited set. WholeObject mode rejects non-zero and
// symbolic offsets recursively through PHI/select.
VirtualIdentityResult resolveVirtualIdentity(
    Value *V, const PEABlockState &State, const AliasMap &Aliases,
    const DataLayout &DL,
    VirtualIdentityMode Mode = VirtualIdentityMode::BaseObject);

// Compatibility wrapper for callers interested only in a defined base-object
// identity.
std::optional<ObjectID> resolveVirtualRef(Value *V, const PEABlockState &State,
                                          const AliasMap &Aliases,
                                          const DataLayout &DL);

// Whether V is provably unable to denote TargetID's virtual allocation.
// This is deliberately target-relative: an identity-Unknown PHI/select may
// still be distinct when every alternative is external, but not when any
// alternative can carry TargetID, poison, undef, a derived address, or an
// unrecognised pointer-producing structure.
bool isProvablyDistinctFromVirtual(Value *V, ObjectID TargetID,
                                   const PEABlockState &State,
                                   const AliasMap &Aliases,
                                   const DataLayout &DL);

// Resolve V to the byte offset from its (presumed virtual) base pointer.
// Returns std::nullopt if V is not a constant-offset access (e.g., GEP with
// non-constant index, inttoptr, or unrecognised pattern).
std::optional<int64_t> resolveFieldOffset(Value *Ptr, const DataLayout &DL);

// Walk Root's users through pointer-value carriers that do not themselves
// observe the pointer (GEP/casts/freeze/PHI/select and transparent pointer
// intrinsics). Return true when a semantic use is not accepted by IsRemoved.
// Analysis uses this for final NeverEscapes eligibility; the transform repeats
// it as a debug invariant against the committed effect plan.
bool hasUnremovedSemanticUses(Value *Root,
                              function_ref<bool(const Use &)> IsRemoved);

// Find the start index (into the "deopt" bundle's Inputs) of the CURRENT
// (innermost) deopt scope's duplicated-BCI pair. A Jeandle deopt bundle is
// [root scope][inlinee scope]... with the innermost (current-method) scope
// LAST, each scope opening with an adjacent pair of equal-valued i32
// constants (the duplicated BCI marker; the root scope's pair is preceded by
// an i64 should_reexecute slot, inlinee scopes by a MethodType marker pair).
// The scan runs BACKWARD over the bundle inputs so inlinee scopes (appended
// last) are found first. Returns std::nullopt for a missing bundle, a
// malformed pair (mismatched adjacent values), or no pair at all — callers
// must treat those as "scope boundaries unknown" and bail conservatively
// (NEVER report_fatal_error on arbitrary IR: PEA may run on any legal LLVM
// IR, not only frontend-produced bundles).
std::optional<unsigned> findInnermostDeoptScopeBCIPairStart(const CallBase &CB);

/// Returns the start index of the FIRST (root) scope's duplicated-BCI pair in
/// the "deopt" operand bundle of CB, or std::nullopt if the bundle is missing
/// or carries no adjacent equal-i32 pair. A bundle is laid out as
/// [root scope][inlinee scope]... and every scope begins with a duplicated
/// BCI marker (two adjacent equal i32 constants). The marker is always
/// immediately preceded by at least one i64 (the should_reexecute slot; an
/// inlinee scope additionally carries its MethodType pair), and every i32
/// slot VALUE is always followed by an i64 encoding — so an adjacent
/// equal-i32 pair can only ever be a scope's BCI marker, and the FIRST one
/// anchors the root scope. PEA places ALL VO descriptors into the root
/// scope's VO section — the deopt-point-level object pool, whose descriptor
/// records physically precede the scope-value records in the bundle's wire
/// order — so this finder (not the innermost one) anchors the descriptor
/// insert position. Graceful: returns std::nullopt on malformed bundles so
/// callers can bail conservatively.
std::optional<unsigned> findFirstDeoptScopeBCIPairStart(const CallBase &CB);

// Returns the klass pointer (as uintptr_t) attached to the allocation call's
// klass argument, or 0 if not statically known.  Wraps
// jeandle::extractKlassConstant for the allocation-specific operand index.
uintptr_t extractAllocationKlass(const CallBase *AllocCB);

// Returns the constant size-in-bytes operand of jeandle.new_instance.
// std::nullopt if non-constant.
std::optional<uint32_t> extractInstanceSize(const CallBase *NewInstance);

// Returns the constant length operand of jeandle.new_array.
// std::nullopt if non-constant.
std::optional<uint32_t> extractArrayLength(const CallBase *NewArray);

} // namespace llvm::jeandle::pea

#endif
