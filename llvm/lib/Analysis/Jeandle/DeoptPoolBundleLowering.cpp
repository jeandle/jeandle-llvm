//===- DeoptPoolBundleLowering.cpp - Complete deopt bundle plans ----------===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#include "llvm/Analysis/Jeandle/DeoptPoolBundleLowering.h"

#include "llvm/ADT/SmallBitVector.h"
#include "llvm/IR/Constants.h"
#include "llvm/IR/DerivedTypes.h"
#include "llvm/IR/InstrTypes.h"
#include "llvm/IR/Jeandle/Metadata.h"
#include "llvm/IR/LLVMContext.h"
#include "llvm/IR/Type.h"
#include "llvm/Support/ErrorHandling.h"

#include <limits>
#include <utility>

#include "llvm/ADT/DenseMap.h"

using namespace llvm;
using namespace llvm::jeandle;
using namespace llvm::jeandle::pea;

namespace llvm::jeandle::pea {

// Factory funnel for FinalDeoptPoolBundlePlan, whose constructor is private
// so that only the lowering builder can produce a (validated) plan.
struct FinalDeoptPoolBundlePlanAccess {
  static FinalDeoptPoolBundlePlan
  create(ParsedDeoptBundle Source, FinalDeoptPoolGraphPlan Graph,
         SmallVector<FinalDeoptPoolBundleToken, 32> Tokens,
         SmallVector<FinalDeoptPoolCurrentOccurrence, 8> CurrentOccurrences,
         bool NeedsRewrite) {
    return FinalDeoptPoolBundlePlan(
        std::move(Source), std::move(Graph), std::move(Tokens),
        std::move(CurrentOccurrences), NeedsRewrite);
  }
};

} // namespace llvm::jeandle::pea

namespace llvm::jeandle::pea {

// A tracked token snapshots the value's type at plan time; serialization
// later re-checks liveness and this exact type against the live IR.
FinalDeoptPoolBundleToken FinalDeoptPoolBundleToken::tracked(Value *V) {
  FinalDeoptPoolBundleToken Token;
  Token.Kind = FinalDeoptPoolBundleTokenKind::TrackedValue;
  Token.Tracked = V;
  Token.ExpectedTrackedType = V ? V->getType() : nullptr;
  return Token;
}

FinalDeoptPoolBundleToken
FinalDeoptPoolBundleToken::immediateI32(uint32_t Value) {
  FinalDeoptPoolBundleToken Token;
  Token.Kind = FinalDeoptPoolBundleTokenKind::ImmediateI32;
  Token.Immediate = Value;
  return Token;
}

FinalDeoptPoolBundleToken
FinalDeoptPoolBundleToken::immediateI64(uint64_t Value) {
  FinalDeoptPoolBundleToken Token;
  Token.Kind = FinalDeoptPoolBundleTokenKind::ImmediateI64;
  Token.Immediate = Value;
  return Token;
}

// Null unless the token carries a live SSA value.
Value *FinalDeoptPoolBundleToken::trackedValue() const {
  return Kind == FinalDeoptPoolBundleTokenKind::TrackedValue
             ? static_cast<Value *>(Tracked)
             : nullptr;
}

FinalDeoptPoolBundlePlan::FinalDeoptPoolBundlePlan(
    ParsedDeoptBundle Source, FinalDeoptPoolGraphPlan Graph,
    SmallVector<FinalDeoptPoolBundleToken, 32> Tokens,
    SmallVector<FinalDeoptPoolCurrentOccurrence, 8> CurrentOccurrences,
    bool NeedsRewrite)
    : Source(std::move(Source)), Graph(std::move(Graph)),
      Tokens(std::move(Tokens)),
      CurrentOccurrences(std::move(CurrentOccurrences)),
      NeedsRewrite(NeedsRewrite) {}

bool FinalDeoptPoolBundlePlan::coversExactOccurrence(
    DeoptPoolSemanticCellID SemanticCell, CurrentDeoptNodeID CurrentID) const {
  // Linear scan: occurrences are few (one per current cell binding plus the
  // generated descriptor and field occurrences), so a map would not pay off.
  for (const FinalDeoptPoolCurrentOccurrence &Occurrence : CurrentOccurrences)
    if (Occurrence.SemanticCell == SemanticCell &&
        Occurrence.CurrentID == CurrentID)
      return true;
  return false;
}

} // namespace llvm::jeandle::pea

namespace {

// The deopt value encoding stores its index as a signed i32, so wire IDs,
// field offsets, and field counts must all fit in INT32_MAX.
constexpr unsigned MaxSignedWireValue =
    static_cast<unsigned>(std::numeric_limits<int32_t>::max());

// Pack one deopt value encoding onto the wire as an i64:
//   [63:32] index   [31:16] value type   [15:0] basic type.
uint64_t encodeDeoptValue(uint32_t Index,
                          DeoptValueEncoding::DeoptValueType ValueType,
                          HotspotBasicType BasicType) {
  return (static_cast<uint64_t>(Index) << 32) |
         (static_cast<uint64_t>(ValueType) << 16) |
         static_cast<uint64_t>(BasicType);
}

PrepareFinalDeoptPoolBundleResult
prepareError(FinalDeoptPoolBundleErrorCode Code, uint64_t Subject = 0) {
  PrepareFinalDeoptPoolBundleResult Result;
  Result.Error = FinalDeoptPoolBundleError{Code, Subject};
  return Result;
}

SerializeFinalDeoptPoolBundleResult
serializeError(FinalDeoptPoolBundleErrorCode Code, uint64_t Subject = 0) {
  SerializeFinalDeoptPoolBundleResult Result;
  Result.Error = FinalDeoptPoolBundleError{Code, Subject};
  return Result;
}

// Wire-type compatibility of a scalar payload: sub-int integers widen to
// T_INT; a T_OBJECT value must be a Java-heap pointer, and only a null
// constant is accepted because other constants cannot be followed through a
// tracking handle; T_ILLEGAL cells carry a zero constant.
bool isValidScalarValue(HotspotBasicType BasicType, Value *V) {
  if (!V)
    return false;
  Type *Ty = V->getType();
  switch (BasicType) {
  case T_INT:
    return Ty->isIntegerTy() && Ty->getIntegerBitWidth() <= 32;
  case T_LONG:
    return Ty->isIntegerTy(64);
  case T_FLOAT:
    return Ty->isFloatTy();
  case T_DOUBLE:
    return Ty->isDoubleTy();
  case T_OBJECT: {
    auto *PT = dyn_cast<PointerType>(Ty);
    return PT && PT->getAddressSpace() == AddrSpace::JavaHeapAddrSpace &&
           (!isa<Constant>(V) || isa<ConstantPointerNull>(V));
  }
  case T_ILLEGAL: {
    auto *CI = dyn_cast<ConstantInt>(V);
    return CI && CI->isZero();
  }
  default:
    return false;
  }
}

// Where a source root cell was parsed from: a scope value (local or stack
// slot) or a monitor owner. Exactly one of the two pointers is set, selected
// by Kind.
struct SourceRootLocation {
  DeoptPoolRootKind Kind;
  const ParsedDeoptScopeValue *ScopeValue = nullptr;
  const ParsedDeoptMonitor *Monitor = nullptr;
};

// Position of one descriptor field in the parsed source bundle.
struct SourceFieldLocation {
  unsigned DescriptorIndex;
  unsigned FieldIndex;
};

// Builds the FinalDeoptPoolBundlePlan for one safepoint. The build runs
// during analysis and performs no IR mutation; every inconsistency is
// reported as data through fail(), never asserted. The pipeline is:
//   1. validateSourceTree: re-validate the parsed bundle against its
//      structural fingerprint, account for every source operand exactly
//      once, and record where each root/field cell was parsed from;
//   2. collectScalarTokens + validateGraph: index the scalar-token table,
//      then check the graph plan against the parsed source — dense wire IDs,
//      legacy descriptors kept verbatim, current members in plan order, and
//      every source VORef still represented;
//   3. classifyCurrentOccurrences: map every exact current-cell binding to
//      its disposition (rewritten to a VORef, or removed with a pruned
//      descriptor) and prove every plan-side current reference has one;
//   4. emitCompleteBundle + validateOccurrenceCompletion: emit the complete
//      token list in wire order and prove every rewritten occurrence
//      received its output operands.
class BundlePlanBuilder {
public:
  BundlePlanBuilder(const ParsedDeoptBundle &Source,
                    const FinalDeoptPoolGraphPlan &Graph,
                    ArrayRef<DeoptPoolScalarTokenBinding> ScalarTokens,
                    ArrayRef<DeoptPoolCurrentCellBinding> CurrentCells)
      : Source(Source), Graph(Graph), ScalarTokenInputs(ScalarTokens),
        CurrentCellInputs(CurrentCells),
        AccountedSourceCells(Source.OriginalInputs.size()) {}

  PrepareFinalDeoptPoolBundleResult build() {
    // copyParsedDeoptBundleInputs follows the WeakTrackingVH-captured inputs,
    // rejects any nulled value, and validates the fingerprint. build() runs
    // during analysis where the IR is immutable, so the live bundle operands
    // still equal the parsed snapshot; the post-RAUW live-operand recheck is
    // performed by serializeFinalDeoptPoolBundlePlan in the transform phase.
    if (!copyParsedDeoptBundleInputs(Source, SourceValues))
      return prepareError(
          FinalDeoptPoolBundleErrorCode::InvalidSourceFingerprint);

    if (!validateSourceTree())
      return prepareError(Error->Code, Error->Subject);
    if (!collectScalarTokens())
      return prepareError(Error->Code, Error->Subject);
    if (!validateGraph())
      return prepareError(Error->Code, Error->Subject);
    if (!classifyCurrentOccurrences())
      return prepareError(Error->Code, Error->Subject);
    if (!emitCompleteBundle())
      return prepareError(Error->Code, Error->Subject);
    if (!validateOccurrenceCompletion())
      return prepareError(Error->Code, Error->Subject);

    PrepareFinalDeoptPoolBundleResult Result;
    Result.Plan = FinalDeoptPoolBundlePlanAccess::create(
        Source, Graph, std::move(Tokens), std::move(CurrentOccurrences),
        Graph.needsRewrite());
    return Result;
  }

private:
  // Record the first failure and report it; later failures are dropped.
  bool fail(FinalDeoptPoolBundleErrorCode Code, uint64_t Subject = 0) {
    if (!Error)
      Error = FinalDeoptPoolBundleError{Code, Subject};
    return false;
  }

  // Check one parsed cell against the fingerprint and claim its operand.
  // The fingerprint cell must agree on role and operand index and match the
  // live operand's type (constants' exact bits were already checked when the
  // snapshot was copied). Each operand may be claimed only once; together
  // with the final count check in validateSourceTree this proves the parsed
  // tree covers the bundle exactly.
  bool validateAndAccountCell(const DeoptSemanticCell &Cell,
                              DeoptSemanticCellRole ExpectedRole) {
    unsigned Index = Cell.OperandIndex;
    if (Cell.Role != ExpectedRole || Index >= Source.OriginalInputs.size() ||
        Index >= Source.Fingerprint.Cells.size())
      return fail(FinalDeoptPoolBundleErrorCode::UnexpectedSemanticCellRole,
                  Index);
    const DeoptStructuralCell &Fingerprint = Source.Fingerprint.Cells[Index];
    if (Fingerprint.Role != ExpectedRole || Fingerprint.OperandIndex != Index ||
        Fingerprint.OperandType != SourceValues[Index]->getType())
      return fail(FinalDeoptPoolBundleErrorCode::InvalidSourceFingerprint,
                  Index);
    if (AccountedSourceCells.test(Index))
      return fail(FinalDeoptPoolBundleErrorCode::DuplicateSemanticCell, Index);
    AccountedSourceCells.set(Index);
    return true;
  }

  // Record where a root value cell was parsed from; two roots sharing one
  // cell would make the later exact-occurrence lookups ambiguous.
  bool addRootLocation(const DeoptSemanticCell &Cell,
                       SourceRootLocation Location) {
    if (!SourceRoots.try_emplace(Cell.OperandIndex, Location).second)
      return fail(FinalDeoptPoolBundleErrorCode::DuplicateSemanticCell,
                  Cell.OperandIndex);
    return true;
  }

  // Validate a scope value's encoding/value cell pair and register the value
  // cell as a root of the given kind.
  bool validateScopeValue(const ParsedDeoptScopeValue &Value,
                          DeoptPoolRootKind Kind) {
    if (!validateAndAccountCell(Value.EncodingCell,
                                DeoptSemanticCellRole::ScopeValueEncoding) ||
        !validateAndAccountCell(Value.ValueCell,
                                DeoptSemanticCellRole::ScopeValue) ||
        !addRootLocation(Value.ValueCell,
                         SourceRootLocation{Kind, &Value, nullptr}))
      return false;
    return true;
  }

  // Validate one scope's cells in wire order: optional method marker,
  // optional should-reexecute flag, the duplicated equal-BCI pair that opens
  // the scope, then locals, stack, monitors, and the optional orig-pc
  // marker. Locals, stack slots, and monitor owners are the root cells.
  bool validateScope(const ParsedDeoptScope &Scope) {
    if (Scope.Method) {
      if (!validateAndAccountCell(Scope.Method->EncodingCell,
                                  DeoptSemanticCellRole::MethodEncoding) ||
          !validateAndAccountCell(Scope.Method->ValueCell,
                                  DeoptSemanticCellRole::MethodValue))
        return false;
    }
    if (Scope.ShouldReexecuteCell &&
        !validateAndAccountCell(*Scope.ShouldReexecuteCell,
                                DeoptSemanticCellRole::ShouldReexecute))
      return false;
    if (!validateAndAccountCell(Scope.FirstBCICell,
                                DeoptSemanticCellRole::BCI) ||
        !validateAndAccountCell(Scope.SecondBCICell,
                                DeoptSemanticCellRole::BCI))
      return false;
    for (const ParsedDeoptScopeValue &Value : Scope.Locals)
      if (!validateScopeValue(Value, DeoptPoolRootKind::Local))
        return false;
    for (const ParsedDeoptScopeValue &Value : Scope.Stack)
      if (!validateScopeValue(Value, DeoptPoolRootKind::Stack))
        return false;
    for (const ParsedDeoptMonitor &Monitor : Scope.Monitors) {
      if (!validateAndAccountCell(Monitor.EncodingCell,
                                  DeoptSemanticCellRole::MonitorEncoding) ||
          !validateAndAccountCell(Monitor.OwnerCell,
                                  DeoptSemanticCellRole::MonitorOwner) ||
          !validateAndAccountCell(Monitor.LockCell,
                                  DeoptSemanticCellRole::MonitorLock) ||
          !addRootLocation(Monitor.OwnerCell,
                           SourceRootLocation{DeoptPoolRootKind::MonitorOwner,
                                              nullptr, &Monitor}))
        return false;
    }
    if (Scope.OrigPc) {
      if (!validateAndAccountCell(Scope.OrigPc->EncodingCell,
                                  DeoptSemanticCellRole::OrigPcEncoding) ||
          !validateAndAccountCell(Scope.OrigPc->ValueCell,
                                  DeoptSemanticCellRole::OrigPcValue))
        return false;
    }
    return true;
  }

  // Walk the whole parsed tree, validating and claiming every operand. The
  // closing count check rejects any operand the tree did not mention, so a
  // stale or misparsed bundle cannot slip through with extra cells.
  bool validateSourceTree() {
    if (Source.OriginalInputs.size() != Source.Fingerprint.Cells.size())
      return fail(FinalDeoptPoolBundleErrorCode::InvalidSourceFingerprint);

    // Descriptors first: they occupy the root scope's VO section, ahead of
    // all scope values. Each field's value cell is remembered so overlay and
    // pruning checks can find its parsed form later.
    for (unsigned DescriptorIndex = 0;
         DescriptorIndex < Source.Descriptors.size(); ++DescriptorIndex) {
      const ParsedDeoptDescriptor &Descriptor =
          Source.Descriptors[DescriptorIndex];
      if (!validateAndAccountCell(Descriptor.HeaderCell,
                                  DeoptSemanticCellRole::DescriptorHeader) ||
          !validateAndAccountCell(Descriptor.KlassCell,
                                  DeoptSemanticCellRole::DescriptorKlass) ||
          !validateAndAccountCell(Descriptor.FieldCountCell,
                                  DeoptSemanticCellRole::DescriptorFieldCount))
        return false;
      for (unsigned FieldIndex = 0; FieldIndex < Descriptor.Fields.size();
           ++FieldIndex) {
        const ParsedDeoptField &Field = Descriptor.Fields[FieldIndex];
        if (!validateAndAccountCell(
                Field.EncodingCell,
                DeoptSemanticCellRole::DescriptorFieldEncoding) ||
            !validateAndAccountCell(
                Field.ValueCell, DeoptSemanticCellRole::DescriptorFieldValue))
          return false;
        if (!SourceFields
                 .try_emplace(Field.ValueCell.OperandIndex,
                              SourceFieldLocation{DescriptorIndex, FieldIndex})
                 .second)
          return fail(FinalDeoptPoolBundleErrorCode::DuplicateSemanticCell,
                      Field.ValueCell.OperandIndex);
      }
    }

    for (const ParsedDeoptScope &Scope : Source.Scopes)
      if (!validateScope(Scope))
        return false;
    for (const ParsedDeoptMarker &Marker : Source.NarrowOopMarkers) {
      if (!validateAndAccountCell(Marker.EncodingCell,
                                  DeoptSemanticCellRole::NarrowOopEncoding) ||
          !validateAndAccountCell(Marker.ValueCell,
                                  DeoptSemanticCellRole::NarrowOopValue))
        return false;
    }

    if (AccountedSourceCells.count() != Source.OriginalInputs.size())
      return fail(FinalDeoptPoolBundleErrorCode::InvalidSourceFingerprint);
    return true;
  }

  // Index the caller-provided scalar-token table, rejecting dead values and
  // duplicate tokens.
  bool collectScalarTokens() {
    for (const DeoptPoolScalarTokenBinding &Binding : ScalarTokenInputs) {
      Value *V = Binding.Value;
      if (!V)
        return fail(FinalDeoptPoolBundleErrorCode::DeadTrackedValue,
                    Binding.Token);
      if (!ScalarTokens.try_emplace(Binding.Token, Binding.Value).second)
        return fail(FinalDeoptPoolBundleErrorCode::DuplicateScalarToken,
                    Binding.Token);
    }
    return true;
  }

  // Resolve a scalar token to its live SSA value and check the value's type
  // against the slot's basic type. Records the specific failure on miss.
  Value *lookupScalar(uint64_t Token, HotspotBasicType BasicType) {
    auto It = ScalarTokens.find(Token);
    if (It == ScalarTokens.end()) {
      fail(FinalDeoptPoolBundleErrorCode::MissingScalarToken, Token);
      return nullptr;
    }
    Value *V = It->second;
    if (!V) {
      fail(FinalDeoptPoolBundleErrorCode::DeadTrackedValue, Token);
      return nullptr;
    }
    if (!isValidScalarValue(BasicType, V)) {
      fail(FinalDeoptPoolBundleErrorCode::InvalidScalarType, Token);
      return nullptr;
    }
    return V;
  }

  // The analysis-local current ID behind a final wire ID, or nullopt when
  // the wire ID names a legacy node.
  std::optional<CurrentDeoptNodeID> currentIDForWire(uint32_t WireID) const {
    auto It = CurrentByWire.find(WireID);
    if (It == CurrentByWire.end())
      return std::nullopt;
    return It->second;
  }

  // Check one final field: the offset must fit the signed wire encoding, a
  // reference must be T_OBJECT with an in-range target, and a scalar token
  // must resolve to a live, type-compatible value.
  bool validateGraphField(const FinalDeoptPoolField &Field) {
    if (Field.Offset < 0 ||
        static_cast<uint64_t>(Field.Offset) > MaxSignedWireValue)
      return fail(FinalDeoptPoolBundleErrorCode::InvalidFieldOffset,
                  static_cast<uint64_t>(Field.Offset));
    if (Field.isReference()) {
      if (Field.BasicType != T_OBJECT ||
          Field.TargetWireID >= Graph.nodes().size())
        return fail(FinalDeoptPoolBundleErrorCode::InvalidWireGraph,
                    Field.TargetWireID);
    } else if (!lookupScalar(Field.ScalarToken, Field.BasicType)) {
      return false;
    }
    return true;
  }

  // Check the graph plan against the parsed source: wire IDs dense and in
  // node order, every kept legacy descriptor identical to its parsed form,
  // current nodes consistent with currentMembers(), every overlay-induced
  // reference pointing at a current node, and every source VORef root still
  // represented by a final root. Also builds the by-cell lookup maps and
  // LegacySourceKept used by occurrence classification.
  bool validateGraph() {
    LegacySourceKept.resize(Source.Descriptors.size());
    unsigned CurrentMemberIndex = 0;
    for (unsigned NodeIndex = 0; NodeIndex < Graph.nodes().size();
         ++NodeIndex) {
      const FinalDeoptPoolNode &Node = Graph.nodes()[NodeIndex];
      // Wire IDs are the node's own index: dense, ordered, and encodable.
      if (Node.WireID != NodeIndex || Node.WireID > MaxSignedWireValue ||
          Node.Klass == 0 || Node.Fields.size() > MaxSignedWireValue)
        return fail(FinalDeoptPoolBundleErrorCode::InvalidWireGraph,
                    Node.WireID);

      if (Node.Origin == DeoptPoolNodeOrigin::Legacy) {
        // A kept legacy node must be identical to the parsed descriptor it
        // claims to keep: same klass, shape, and field layout, with cells
        // matching the parsed field cells one to one.
        if (Node.LegacySourceIndex >= Source.Descriptors.size() ||
            LegacySourceKept.test(Node.LegacySourceIndex))
          return fail(FinalDeoptPoolBundleErrorCode::InvalidLegacySource,
                      Node.LegacySourceIndex);
        LegacySourceKept.set(Node.LegacySourceIndex);
        const ParsedDeoptDescriptor &Parsed =
            Source.Descriptors[Node.LegacySourceIndex];
        if (Node.Klass != Parsed.Klass || Node.IsArray != Parsed.IsArray ||
            Node.IsBoxed != Parsed.IsBoxed ||
            Node.Fields.size() != Parsed.Fields.size())
          return fail(FinalDeoptPoolBundleErrorCode::InvalidLegacySource,
                      Node.LegacySourceIndex);
        for (unsigned FieldIndex = 0; FieldIndex < Node.Fields.size();
             ++FieldIndex) {
          const FinalDeoptPoolField &Field = Node.Fields[FieldIndex];
          const ParsedDeoptField &ParsedField = Parsed.Fields[FieldIndex];
          if (Field.SemanticCell != ParsedField.ValueCell.OperandIndex ||
              Field.Offset != ParsedField.Offset ||
              (ParsedField.TargetWireID.has_value() && !Field.isReference()) ||
              (!ParsedField.TargetWireID.has_value() && !Field.isReference() &&
               Field.BasicType != ParsedField.Encoding.BasicType))
            return fail(FinalDeoptPoolBundleErrorCode::InvalidLegacySource,
                        Field.SemanticCell);
          if (!FinalFieldsByCell.try_emplace(Field.SemanticCell, &Field).second)
            return fail(FinalDeoptPoolBundleErrorCode::DuplicateSemanticCell,
                        Field.SemanticCell);
          if (!validateGraphField(Field))
            return false;
        }
      } else {
        // A current node must appear exactly at its position in
        // currentMembers() and its fields must be newly emitted (no source
        // cells).
        if (Node.CurrentID == InvalidCurrentDeoptNodeID ||
            CurrentMemberIndex >= Graph.currentMembers().size() ||
            Graph.currentMembers()[CurrentMemberIndex] != Node.CurrentID ||
            !CurrentByWire.try_emplace(Node.WireID, Node.CurrentID).second)
          return fail(FinalDeoptPoolBundleErrorCode::InvalidWireGraph,
                      Node.CurrentID);
        ++CurrentMemberIndex;
        for (const FinalDeoptPoolField &Field : Node.Fields) {
          if (Field.SemanticCell != InvalidDeoptPoolSemanticCellID)
            return fail(
                FinalDeoptPoolBundleErrorCode::UnexpectedSemanticCellRole,
                Field.SemanticCell);
          if (!validateGraphField(Field))
            return false;
        }
      }
    }
    if (CurrentMemberIndex != Graph.currentMembers().size())
      return fail(FinalDeoptPoolBundleErrorCode::InvalidWireGraph);

    // A legacy field that was scalar in the source but is a reference in the
    // plan (i.e. overlaid) must point at a current node; re-pointing it at a
    // legacy node would silently change the original wire semantics. The
    // SourceFields lookup cannot miss: every final legacy field's cell was
    // matched to a parsed field cell above.
    for (const auto &[Cell, Field] : FinalFieldsByCell) {
      const SourceFieldLocation &Location = SourceFields.find(Cell)->second;
      const ParsedDeoptField &ParsedField =
          Source.Descriptors[Location.DescriptorIndex]
              .Fields[Location.FieldIndex];
      if (!ParsedField.TargetWireID && Field->isReference() &&
          !currentIDForWire(Field->TargetWireID))
        return fail(FinalDeoptPoolBundleErrorCode::InvalidWireGraph, Cell);
    }

    // Roots: known source cell, matching kind, and an overlaid (formerly
    // scalar) root must likewise target a current node.
    for (const FinalDeoptPoolRoot &Root : Graph.roots()) {
      if (Root.SemanticCell == InvalidDeoptPoolSemanticCellID ||
          Root.TargetWireID >= Graph.nodes().size() ||
          !FinalRootsByCell.try_emplace(Root.SemanticCell, &Root).second)
        return fail(FinalDeoptPoolBundleErrorCode::InvalidWireGraph,
                    Root.SemanticCell);
      auto SourceRoot = SourceRoots.find(Root.SemanticCell);
      if (SourceRoot == SourceRoots.end())
        return fail(FinalDeoptPoolBundleErrorCode::UnexpectedSemanticCellRole,
                    Root.SemanticCell);
      if (SourceRoot->second.Kind != Root.Kind)
        return fail(FinalDeoptPoolBundleErrorCode::RootKindMismatch,
                    Root.SemanticCell);
      bool WasVORef =
          SourceRoot->second.ScopeValue
              ? SourceRoot->second.ScopeValue->TargetWireID.has_value()
              : SourceRoot->second.Monitor->Eliminated;
      if (!WasVORef && !currentIDForWire(Root.TargetWireID))
        return fail(FinalDeoptPoolBundleErrorCode::InvalidWireGraph,
                    Root.SemanticCell);
    }

    // Every source VORef outside a descriptor must remain represented by a
    // final root. Scalar roots may legitimately remain scalar.
    for (const auto &[Cell, Location] : SourceRoots) {
      bool WasVORef = Location.ScopeValue
                          ? Location.ScopeValue->TargetWireID.has_value()
                          : Location.Monitor->Eliminated;
      if (WasVORef && !FinalRootsByCell.count(Cell))
        return fail(FinalDeoptPoolBundleErrorCode::InvalidWireGraph, Cell);
    }
    return true;
  }

  // Map a parsed root location to its occurrence kind.
  FinalDeoptPoolOccurrenceKind
  occurrenceKind(const SourceRootLocation &Location) const {
    switch (Location.Kind) {
    case DeoptPoolRootKind::Local:
      return FinalDeoptPoolOccurrenceKind::Local;
    case DeoptPoolRootKind::Stack:
      return FinalDeoptPoolOccurrenceKind::Stack;
    case DeoptPoolRootKind::MonitorOwner:
      return FinalDeoptPoolOccurrenceKind::MonitorOwner;
    }
    llvm_unreachable("unknown root kind");
  }

  // Map each exact current-cell binding to its occurrence record. Three
  // shapes are possible: the cell is a final root (an overlaid scope value
  // or monitor owner), the cell is a field of a kept legacy descriptor (an
  // overlaid field), or the cell sits in a pruned descriptor and disappears
  // with it.
  bool classifyCurrentOccurrences() {
    DenseMap<DeoptPoolSemanticCellID, CurrentDeoptNodeID> UniqueCells;
    for (const DeoptPoolCurrentCellBinding &Binding : CurrentCellInputs) {
      if (Binding.SemanticCell == InvalidDeoptPoolSemanticCellID ||
          Binding.CurrentID == InvalidCurrentDeoptNodeID ||
          !UniqueCells.try_emplace(Binding.SemanticCell, Binding.CurrentID)
               .second)
        return fail(FinalDeoptPoolBundleErrorCode::DuplicateCurrentOccurrence,
                    Binding.SemanticCell);

      FinalDeoptPoolCurrentOccurrence Occurrence;
      Occurrence.CurrentID = Binding.CurrentID;
      Occurrence.SemanticCell = Binding.SemanticCell;

      auto Root = FinalRootsByCell.find(Binding.SemanticCell);
      if (Root != FinalRootsByCell.end()) {
        // Overlaid root: the final root must target the bound current node,
        // and the source cell must have been a scalar oop (monitor owners
        // are object-typed by construction).
        auto TargetCurrent = currentIDForWire(Root->second->TargetWireID);
        auto SourceRoot = SourceRoots.find(Binding.SemanticCell);
        if (!TargetCurrent || *TargetCurrent != Binding.CurrentID ||
            SourceRoot == SourceRoots.end())
          return fail(
              FinalDeoptPoolBundleErrorCode::CurrentOccurrenceNotCovered,
              Binding.SemanticCell);
        bool WasScalar =
            SourceRoot->second.ScopeValue
                ? !SourceRoot->second.ScopeValue->TargetWireID.has_value()
                : !SourceRoot->second.Monitor->Eliminated;
        bool IsObjectScalar =
            SourceRoot->second.ScopeValue
                ? SourceRoot->second.ScopeValue->Encoding.BasicType == T_OBJECT
                : true;
        if (!WasScalar || !IsObjectScalar)
          return fail(
              FinalDeoptPoolBundleErrorCode::CurrentOccurrenceNotCovered,
              Binding.SemanticCell);
        Occurrence.Kind = occurrenceKind(SourceRoot->second);
        Occurrence.Disposition =
            FinalDeoptPoolOccurrenceDisposition::RewrittenToVORef;
      } else {
        auto Field = FinalFieldsByCell.find(Binding.SemanticCell);
        if (Field != FinalFieldsByCell.end()) {
          // Overlaid field of a kept descriptor: the final field must be a
          // reference to the bound current node, and the source field must
          // have been a scalar oop (not already a VORef).
          const FinalDeoptPoolField *FinalField = Field->second;
          auto SourceField = SourceFields.find(Binding.SemanticCell);
          auto TargetCurrent = FinalField->isReference()
                                   ? currentIDForWire(FinalField->TargetWireID)
                                   : std::nullopt;
          if (!TargetCurrent || *TargetCurrent != Binding.CurrentID ||
              SourceField == SourceFields.end() ||
              Source.Descriptors[SourceField->second.DescriptorIndex]
                  .Fields[SourceField->second.FieldIndex]
                  .TargetWireID.has_value() ||
              Source.Descriptors[SourceField->second.DescriptorIndex]
                      .Fields[SourceField->second.FieldIndex]
                      .Encoding.BasicType != T_OBJECT)
            return fail(
                FinalDeoptPoolBundleErrorCode::CurrentOccurrenceNotCovered,
                Binding.SemanticCell);
          Occurrence.Kind = FinalDeoptPoolOccurrenceKind::DescriptorField;
          Occurrence.Disposition =
              FinalDeoptPoolOccurrenceDisposition::RewrittenToVORef;
        } else {
          // The cell must be a scalar oop field of a pruned descriptor; it
          // vanishes from the wire together with that descriptor.
          auto SourceField = SourceFields.find(Binding.SemanticCell);
          if (SourceField == SourceFields.end() ||
              LegacySourceKept.test(SourceField->second.DescriptorIndex) ||
              Source.Descriptors[SourceField->second.DescriptorIndex]
                  .Fields[SourceField->second.FieldIndex]
                  .TargetWireID.has_value() ||
              Source.Descriptors[SourceField->second.DescriptorIndex]
                      .Fields[SourceField->second.FieldIndex]
                      .Encoding.BasicType != T_OBJECT)
            return fail(
                FinalDeoptPoolBundleErrorCode::CurrentOccurrenceNotCovered,
                Binding.SemanticCell);
          Occurrence.Kind = FinalDeoptPoolOccurrenceKind::DescriptorField;
          Occurrence.Disposition =
              FinalDeoptPoolOccurrenceDisposition::RemovedByPruning;
        }
      }

      ExactOccurrenceByCell[Binding.SemanticCell] = CurrentOccurrences.size();
      CurrentOccurrences.push_back(std::move(Occurrence));
    }

    // Every final source cell rewritten to reference a current node must have
    // an explicit exact-cell binding; current-node fields are newly emitted
    // and therefore have no source occurrence.
    for (const auto &[Cell, Root] : FinalRootsByCell)
      if (currentIDForWire(Root->TargetWireID) &&
          !ExactOccurrenceByCell.count(Cell))
        return fail(FinalDeoptPoolBundleErrorCode::MissingCurrentOccurrence,
                    Cell);
    for (const auto &[Cell, Field] : FinalFieldsByCell)
      if (Field->isReference() && currentIDForWire(Field->TargetWireID) &&
          !ExactOccurrenceByCell.count(Cell))
        return fail(FinalDeoptPoolBundleErrorCode::MissingCurrentOccurrence,
                    Cell);
    return true;
  }

  unsigned appendToken(FinalDeoptPoolBundleToken Token) {
    unsigned Index = Tokens.size();
    Tokens.push_back(std::move(Token));
    return Index;
  }

  // Copy one unchanged source operand into the token stream.
  unsigned appendSource(const DeoptSemanticCell &Cell) {
    return appendToken(
        FinalDeoptPoolBundleToken::tracked(SourceValues[Cell.OperandIndex]));
  }

  // Fill in the output token indices of an exact occurrence once its
  // encoding and value tokens have been emitted. classifyCurrentOccurrences
  // has already proven that every current-referencing cell has a record, so
  // the miss path is defensive only.
  void setExactOccurrenceOutput(DeoptPoolSemanticCellID Cell,
                                unsigned EncodingIndex, unsigned ValueIndex) {
    auto It = ExactOccurrenceByCell.find(Cell);
    if (It == ExactOccurrenceByCell.end())
      return;
    FinalDeoptPoolCurrentOccurrence &Occurrence =
        CurrentOccurrences[It->second];
    Occurrence.OutputEncodingTokenIndex = EncodingIndex;
    Occurrence.OutputValueTokenIndex = ValueIndex;
  }

  // Record an occurrence with no source cell: a current node's own
  // descriptor header, or a reference field of a current node.
  void addGeneratedOccurrence(CurrentDeoptNodeID CurrentID,
                              FinalDeoptPoolOccurrenceKind Kind,
                              std::optional<unsigned> EncodingIndex,
                              std::optional<unsigned> ValueIndex) {
    FinalDeoptPoolCurrentOccurrence Occurrence;
    Occurrence.CurrentID = CurrentID;
    Occurrence.Kind = Kind;
    Occurrence.Disposition =
        FinalDeoptPoolOccurrenceDisposition::RewrittenToVORef;
    Occurrence.OutputEncodingTokenIndex = EncodingIndex;
    Occurrence.OutputValueTokenIndex = ValueIndex;
    CurrentOccurrences.push_back(std::move(Occurrence));
  }

  // Emit one VO descriptor: the header encoding (ScalarValueType with the
  // wire ID as index), the raw klass identity, the field count, then each
  // field's encoding/value pair. Reference fields encode as VORefLocalType
  // with the target's wire ID as an i32 value; scalar fields carry their
  // resolved tracked value. Legacy nodes reuse their parsed cells as
  // provenance; current nodes register generated occurrences instead.
  bool emitDescriptor(const FinalDeoptPoolNode &Node) {
    const ParsedDeoptDescriptor *Parsed = nullptr;
    if (Node.Origin == DeoptPoolNodeOrigin::Legacy)
      Parsed = &Source.Descriptors[Node.LegacySourceIndex];

    unsigned HeaderIndex = appendToken(FinalDeoptPoolBundleToken::immediateI64(
        encodeDeoptValue(Node.WireID, DeoptValueEncoding::ScalarValueType,
                         Node.IsArray ? T_ARRAY : T_OBJECT)));
    appendToken(FinalDeoptPoolBundleToken::immediateI64(Node.Klass));
    uint32_t FieldCount = static_cast<uint32_t>(Node.Fields.size());
    if (Node.IsBoxed)
      FieldCount |= DeoptValueEncoding::BoxedDescriptorFlag;
    appendToken(FinalDeoptPoolBundleToken::immediateI32(FieldCount));

    if (Node.Origin == DeoptPoolNodeOrigin::Current)
      addGeneratedOccurrence(Node.CurrentID,
                             FinalDeoptPoolOccurrenceKind::Descriptor,
                             HeaderIndex, std::nullopt);

    for (unsigned FieldIndex = 0; FieldIndex < Node.Fields.size();
         ++FieldIndex) {
      const FinalDeoptPoolField &Field = Node.Fields[FieldIndex];
      const ParsedDeoptField *ParsedField =
          Parsed ? &Parsed->Fields[FieldIndex] : nullptr;
      unsigned EncodingIndex =
          appendToken(FinalDeoptPoolBundleToken::immediateI64(encodeDeoptValue(
              static_cast<uint32_t>(Field.Offset),
              Field.isReference() ? DeoptValueEncoding::VORefLocalType
                                  : DeoptValueEncoding::LocalType,
              Field.isReference() ? T_OBJECT : Field.BasicType)));

      unsigned ValueIndex;
      if (Field.isReference()) {
        ValueIndex = appendToken(
            FinalDeoptPoolBundleToken::immediateI32(Field.TargetWireID));
        // A reference to a current node needs occurrence bookkeeping: exact
        // for an overlaid legacy field, generated for a current-node field.
        if (auto Current = currentIDForWire(Field.TargetWireID)) {
          if (ParsedField)
            setExactOccurrenceOutput(Field.SemanticCell, EncodingIndex,
                                     ValueIndex);
          else
            addGeneratedOccurrence(
                *Current, FinalDeoptPoolOccurrenceKind::DescriptorField,
                EncodingIndex, ValueIndex);
        }
      } else {
        Value *Scalar = lookupScalar(Field.ScalarToken, Field.BasicType);
        if (!Scalar)
          return false;
        ValueIndex = appendToken(FinalDeoptPoolBundleToken::tracked(Scalar));
      }
    }
    return true;
  }

  // Copy a scope's header cells verbatim: optional method marker, optional
  // should-reexecute flag, and the duplicated BCI pair. The rewrite never
  // changes these.
  void emitScopeHeader(const ParsedDeoptScope &Scope) {
    if (Scope.Method) {
      appendSource(Scope.Method->EncodingCell);
      appendSource(Scope.Method->ValueCell);
    }
    if (Scope.ShouldReexecuteCell)
      appendSource(*Scope.ShouldReexecuteCell);
    appendSource(Scope.FirstBCICell);
    appendSource(Scope.SecondBCICell);
  }

  // Emit one scope value. A cell the plan leaves alone is copied verbatim; a
  // final root is rewritten to a VORef encoding (locals and stack slots use
  // distinct wire types) plus the target's wire ID as an i32 value.
  bool emitScopeValue(const ParsedDeoptScopeValue &Value,
                      DeoptPoolRootKind Kind) {
    auto Root = FinalRootsByCell.find(Value.ValueCell.OperandIndex);
    if (Root == FinalRootsByCell.end()) {
      appendSource(Value.EncodingCell);
      appendSource(Value.ValueCell);
      return true;
    }

    DeoptValueEncoding::DeoptValueType RefType =
        Kind == DeoptPoolRootKind::Local ? DeoptValueEncoding::VORefLocalType
                                         : DeoptValueEncoding::VORefStackType;
    uint32_t WireID = Root->second->TargetWireID;
    unsigned EncodingIndex =
        appendToken(FinalDeoptPoolBundleToken::immediateI64(
            encodeDeoptValue(WireID, RefType, T_OBJECT)));
    unsigned ValueIndex =
        appendToken(FinalDeoptPoolBundleToken::immediateI32(WireID));
    if (currentIDForWire(WireID))
      setExactOccurrenceOutput(Value.ValueCell.OperandIndex, EncodingIndex,
                               ValueIndex);
    return true;
  }

  // Emit one monitor. An untouched owner is copied verbatim (encoding, owner,
  // lock). A rewritten owner becomes an eliminated-monitor encoding — the
  // MonitorType discriminant index 1 marks a PEA-eliminated lock on a virtual
  // object — with the owner VO's wire ID as an i32 value; the basic-lock
  // cell is preserved for the VM to initialize at deopt.
  bool emitMonitor(const ParsedDeoptMonitor &Monitor) {
    auto Root = FinalRootsByCell.find(Monitor.OwnerCell.OperandIndex);
    if (Root == FinalRootsByCell.end()) {
      appendSource(Monitor.EncodingCell);
      appendSource(Monitor.OwnerCell);
      appendSource(Monitor.LockCell);
      return true;
    }

    uint32_t WireID = Root->second->TargetWireID;
    unsigned EncodingIndex =
        appendToken(FinalDeoptPoolBundleToken::immediateI64(encodeDeoptValue(
            /*Index=*/1, DeoptValueEncoding::MonitorType, T_OBJECT)));
    unsigned ValueIndex =
        appendToken(FinalDeoptPoolBundleToken::immediateI32(WireID));
    appendSource(Monitor.LockCell);
    if (currentIDForWire(WireID))
      setExactOccurrenceOutput(Monitor.OwnerCell.OperandIndex, EncodingIndex,
                               ValueIndex);
    return true;
  }

  // Emit a scope's body in wire order: locals, expression stack, monitors,
  // and the optional orig-pc marker.
  bool emitScopeBody(const ParsedDeoptScope &Scope) {
    for (const ParsedDeoptScopeValue &Value : Scope.Locals)
      if (!emitScopeValue(Value, DeoptPoolRootKind::Local))
        return false;
    for (const ParsedDeoptScopeValue &Value : Scope.Stack)
      if (!emitScopeValue(Value, DeoptPoolRootKind::Stack))
        return false;
    for (const ParsedDeoptMonitor &Monitor : Scope.Monitors)
      if (!emitMonitor(Monitor))
        return false;
    if (Scope.OrigPc) {
      appendSource(Scope.OrigPc->EncodingCell);
      appendSource(Scope.OrigPc->ValueCell);
    }
    return true;
  }

  // Emit the complete bundle in wire order: root scope header, then ALL
  // descriptors, then the root scope body, then each inlinee scope, and
  // finally the narrow-oop tail. Placing every descriptor between the root
  // header and the root locals forms the deopt-point-level object pool: the
  // HotSpot parser walks scopes outermost-first and resolves VORefs through
  // a record-level map, so every descriptor must precede any VORef that
  // references it, and inlinee scopes never carry descriptors of their own.
  bool emitCompleteBundle() {
    if (Source.Scopes.empty())
      return fail(FinalDeoptPoolBundleErrorCode::InvalidSourceFingerprint);

    emitScopeHeader(Source.Scopes.front());
    for (const FinalDeoptPoolNode &Node : Graph.nodes())
      if (!emitDescriptor(Node))
        return false;
    if (!emitScopeBody(Source.Scopes.front()))
      return false;

    for (unsigned ScopeIndex = 1; ScopeIndex < Source.Scopes.size();
         ++ScopeIndex) {
      emitScopeHeader(Source.Scopes[ScopeIndex]);
      if (!emitScopeBody(Source.Scopes[ScopeIndex]))
        return false;
    }
    for (const ParsedDeoptMarker &Marker : Source.NarrowOopMarkers) {
      appendSource(Marker.EncodingCell);
      appendSource(Marker.ValueCell);
    }
    return true;
  }

  // Prove emission matched classification: a pruned occurrence must have
  // received no output tokens, and a rewritten occurrence must have received
  // its encoding token and — except for a Descriptor occurrence, which is
  // the header cell alone — its value token.
  bool validateOccurrenceCompletion() {
    for (const FinalDeoptPoolCurrentOccurrence &Occurrence :
         CurrentOccurrences) {
      if (Occurrence.Disposition ==
          FinalDeoptPoolOccurrenceDisposition::RemovedByPruning) {
        if (Occurrence.OutputEncodingTokenIndex ||
            Occurrence.OutputValueTokenIndex)
          return fail(
              FinalDeoptPoolBundleErrorCode::CurrentOccurrenceNotCovered,
              Occurrence.SemanticCell.value_or(0));
        continue;
      }
      if (!Occurrence.OutputEncodingTokenIndex)
        return fail(FinalDeoptPoolBundleErrorCode::CurrentOccurrenceNotCovered,
                    Occurrence.SemanticCell.value_or(0));
      if (Occurrence.Kind != FinalDeoptPoolOccurrenceKind::Descriptor &&
          !Occurrence.OutputValueTokenIndex)
        return fail(FinalDeoptPoolBundleErrorCode::CurrentOccurrenceNotCovered,
                    Occurrence.SemanticCell.value_or(0));
    }
    return true;
  }

  // Builder inputs: the parsed bundle, the graph plan, the scalar-token
  // table, and the exact current-cell table.
  const ParsedDeoptBundle &Source;
  const FinalDeoptPoolGraphPlan &Graph;
  ArrayRef<DeoptPoolScalarTokenBinding> ScalarTokenInputs;
  ArrayRef<DeoptPoolCurrentCellBinding> CurrentCellInputs;

  // Live copies of the source operands, resolved through the source's
  // RAUW-tracking handles at build time.
  SmallVector<Value *, 32> SourceValues;
  // One bit per source operand: claimed by exactly one parsed cell.
  SmallBitVector AccountedSourceCells;
  // One bit per source descriptor: kept as a legacy node in the plan.
  SmallBitVector LegacySourceKept;
  // The first failure recorded by fail().
  std::optional<FinalDeoptPoolBundleError> Error;

  // Lookup maps for per-safepoint plan building. Keys can't reach DenseMap's
  // integer sentinels: semantic cells are bundle operand indices bounded by the
  // operand count (and InvalidDeoptPoolSemanticCellID == UINT32_MAX is rejected
  // before insertion), wire IDs are bounded by MaxSignedWireValue (INT32_MAX),
  // and scalar tokens are a 1-based counter — all far from
  // numeric_limits<uint32_t>::max()/max()-1 and the uint64_t analogs.
  DenseMap<uint64_t, WeakTrackingVH> ScalarTokens;
  // Where each source root/field value cell was parsed from.
  DenseMap<DeoptPoolSemanticCellID, SourceRootLocation> SourceRoots;
  DenseMap<DeoptPoolSemanticCellID, SourceFieldLocation> SourceFields;
  // Final roots/fields of the plan, keyed by their source cell.
  DenseMap<DeoptPoolSemanticCellID, const FinalDeoptPoolRoot *>
      FinalRootsByCell;
  DenseMap<DeoptPoolSemanticCellID, const FinalDeoptPoolField *>
      FinalFieldsByCell;
  // Current-node wire ID to analysis-local ID, for plan nodes only.
  DenseMap<uint32_t, CurrentDeoptNodeID> CurrentByWire;
  // Exact source cell to its index in CurrentOccurrences.
  DenseMap<DeoptPoolSemanticCellID, unsigned> ExactOccurrenceByCell;

  // The output being assembled: the token template in wire order and the
  // classified current-node occurrences.
  SmallVector<FinalDeoptPoolBundleToken, 32> Tokens;
  SmallVector<FinalDeoptPoolCurrentOccurrence, 8> CurrentOccurrences;
};

} // namespace

PrepareFinalDeoptPoolBundleResult
llvm::jeandle::pea::prepareFinalDeoptPoolBundlePlan(
    const ParsedDeoptBundle &Source, const FinalDeoptPoolGraphPlan &Graph,
    ArrayRef<DeoptPoolScalarTokenBinding> ScalarTokens,
    ArrayRef<DeoptPoolCurrentCellBinding> CurrentCells) {
  return BundlePlanBuilder(Source, Graph, ScalarTokens, CurrentCells).build();
}

SerializeFinalDeoptPoolBundleResult
llvm::jeandle::pea::serializeFinalDeoptPoolBundlePlan(
    const FinalDeoptPoolBundlePlan &Plan, const CallBase &CurrentSite) {
  // Post-RAUW recheck against the live IR: the plan was built during
  // analysis, and earlier effects may have rewritten the call since. The
  // bundle must still match the parsed snapshot — grammar constants bit-for
  // bit, semantic values through their tracking handles.
  if (!matchesParsedDeoptBundle(Plan.source(), CurrentSite))
    return serializeError(FinalDeoptPoolBundleErrorCode::StaleSourceBundle);

  SmallVector<Value *, 32> Inputs;
  Inputs.reserve(Plan.tokens().size());
  LLVMContext &Context = CurrentSite.getContext();
  for (unsigned TokenIndex = 0; TokenIndex < Plan.tokens().size();
       ++TokenIndex) {
    const FinalDeoptPoolBundleToken &Token = Plan.tokens()[TokenIndex];
    switch (Token.kind()) {
    case FinalDeoptPoolBundleTokenKind::TrackedValue: {
      // A tracked operand must still be alive and keep the exact type it had
      // at plan time.
      Value *V = Token.trackedValue();
      if (!V)
        return serializeError(FinalDeoptPoolBundleErrorCode::DeadTrackedValue,
                              TokenIndex);
      if (V->getType() != Token.expectedTrackedType())
        return serializeError(FinalDeoptPoolBundleErrorCode::InvalidScalarType,
                              TokenIndex);
      Inputs.push_back(V);
      break;
    }
    case FinalDeoptPoolBundleTokenKind::ImmediateI32:
      Inputs.push_back(ConstantInt::get(Type::getInt32Ty(Context),
                                        Token.immediateI32Value()));
      break;
    case FinalDeoptPoolBundleTokenKind::ImmediateI64:
      Inputs.push_back(ConstantInt::get(Type::getInt64Ty(Context),
                                        Token.immediateI64Value()));
      break;
    }
  }

  SerializeFinalDeoptPoolBundleResult Result;
  Result.Inputs = std::move(Inputs);
  return Result;
}
