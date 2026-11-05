//===- DeoptPoolPlanner.cpp - Semantic deopt object-pool planning ---------===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#include "llvm/Analysis/Jeandle/DeoptPoolPlanner.h"
#include "llvm/ADT/DenseMap.h"
#include "llvm/ADT/SmallBitVector.h"

using namespace llvm;
using namespace llvm::jeandle;
using namespace llvm::jeandle::pea;

namespace llvm::jeandle::pea {

// Factory funnel for FinalDeoptPoolGraphPlan, whose constructor is private
// so that only the planner can produce a (validated) plan.
struct DeoptPoolPlannerAccess {
  static FinalDeoptPoolGraphPlan
  create(SmallVector<FinalDeoptPoolNode, 8> Nodes,
         SmallVector<FinalDeoptPoolRoot, 8> Roots,
         SmallVector<CurrentDeoptNodeID, 8> CurrentMembers, bool NeedsRewrite) {
    FinalDeoptPoolGraphPlan Plan;
    Plan.Nodes = std::move(Nodes);
    Plan.Roots = std::move(Roots);
    Plan.CurrentMembers = std::move(CurrentMembers);
    Plan.NeedsRewrite = NeedsRewrite;
    return Plan;
  }
};

} // namespace llvm::jeandle::pea

namespace {

// Per-cell validation state for one source bundle operand.
struct SemanticCellInfo {
  // Whether an overlay may reclassify this cell as a current reference:
  // reference cells may not; scalar legacy fields only when T_OBJECT; scalar
  // roots unconditionally (their basic type is checked at lowering time).
  bool CanOverlay;
};

DeoptPoolPlannerResult error(DeoptPoolPlannerErrorCode Code, uint32_t Subject) {
  DeoptPoolPlannerResult Result;
  Result.Error = DeoptPoolPlannerError{Code, Subject};
  return Result;
}

// Whether Ref names a node present in the corresponding input table.
bool hasNode(const DeoptPoolNodeRef &Ref,
             const DenseMap<uint32_t, unsigned> &LegacyByWire,
             const DenseMap<CurrentDeoptNodeID, unsigned> &CurrentByID) {
  if (Ref.Namespace == DeoptPoolNodeNamespace::Legacy)
    return LegacyByWire.count(Ref.ID);
  return CurrentByID.count(Ref.ID);
}

// Map an input node ref to its fresh dense wire ID. Callers only query refs
// they reached during the reachability walk, so the lookups cannot miss.
uint32_t finalWireID(const DeoptPoolNodeRef &Ref,
                     const DenseMap<uint32_t, unsigned> &LegacyByWire,
                     const DenseMap<CurrentDeoptNodeID, unsigned> &CurrentByID,
                     ArrayRef<uint32_t> LegacyFinalWire,
                     ArrayRef<uint32_t> CurrentFinalWire) {
  if (Ref.Namespace == DeoptPoolNodeNamespace::Legacy)
    return LegacyFinalWire[LegacyByWire.lookup(Ref.ID)];
  return CurrentFinalWire[CurrentByID.lookup(Ref.ID)];
}

// The target a field effectively points at after overlay redirection: an
// overlaid scalar cell becomes a reference to the overlay's current node.
DeoptPoolNodeRef effectiveFieldTarget(
    const DeoptPoolFieldInput &Field,
    const DenseMap<DeoptPoolSemanticCellID, CurrentDeoptNodeID> &Overlays) {
  auto Overlay = Overlays.find(Field.SemanticCell);
  if (Overlay != Overlays.end())
    return DeoptPoolNodeRef::current(Overlay->second);
  return Field.Target;
}

// Same redirection for a root cell.
DeoptPoolNodeRef effectiveRootTarget(
    const DeoptPoolRootInput &Root,
    const DenseMap<DeoptPoolSemanticCellID, CurrentDeoptNodeID> &Overlays) {
  auto Overlay = Overlays.find(Root.SemanticCell);
  if (Overlay != Overlays.end())
    return DeoptPoolNodeRef::current(Overlay->second);
  return Root.Target;
}

bool isSemanticNoOp(
    const DeoptPoolPlannerInput &Input,
    const DenseMap<DeoptPoolSemanticCellID, CurrentDeoptNodeID> &Overlays,
    ArrayRef<FinalDeoptPoolNode> Nodes, ArrayRef<FinalDeoptPoolRoot> Roots) {
  // A stable second round consists only of the same legacy descriptors and
  // VORef roots with already-dense IDs. SemanticCell is provenance for exact
  // lowering, not wire semantics, so it is intentionally excluded.
  if (Nodes.size() != Input.LegacyNodes.size())
    return false;
  // Every final node must be the corresponding legacy input node, unchanged
  // and in the same position: same wire ID (already dense), klass, shape,
  // and field count.
  for (unsigned I = 0; I < Nodes.size(); ++I) {
    const FinalDeoptPoolNode &Final = Nodes[I];
    const LegacyDeoptPoolNode &Legacy = Input.LegacyNodes[I];
    if (Final.Origin != DeoptPoolNodeOrigin::Legacy ||
        Final.LegacySourceIndex != I || Final.WireID != Legacy.WireID ||
        Final.Klass != Legacy.Klass || Final.IsArray != Legacy.IsArray ||
        Final.IsBoxed != Legacy.IsBoxed ||
        Final.Fields.size() != Legacy.Fields.size())
      return false;
    for (unsigned FieldIndex = 0; FieldIndex < Final.Fields.size();
         ++FieldIndex) {
      const FinalDeoptPoolField &FinalField = Final.Fields[FieldIndex];
      const DeoptPoolFieldInput &LegacyField = Legacy.Fields[FieldIndex];
      if (FinalField.Offset != LegacyField.Offset ||
          FinalField.BasicType != LegacyField.BasicType)
        return false;
      // An overlaid field would have been reclassified as a reference.
      if (Overlays.count(LegacyField.SemanticCell))
        return false;
      if (FinalField.isReference() != LegacyField.isReference())
        return false;
      if (FinalField.isReference()) {
        // A stable reference field still points at the same legacy wire ID.
        if (LegacyField.Target.Namespace != DeoptPoolNodeNamespace::Legacy ||
            FinalField.TargetWireID != LegacyField.Target.ID)
          return false;
      } else if (FinalField.ScalarToken != LegacyField.ScalarToken) {
        return false;
      }
    }
  }

  // Walk input roots and final roots in lockstep. Scalar roots are absent
  // from the plan and skipped; each reference root must still target the
  // same legacy wire ID with the same kind.
  unsigned FinalRootIndex = 0;
  for (const DeoptPoolRootInput &InputRoot : Input.Roots) {
    if (Overlays.count(InputRoot.SemanticCell))
      return false;
    if (!InputRoot.isReference())
      continue;
    if (FinalRootIndex == Roots.size() ||
        InputRoot.Target.Namespace != DeoptPoolNodeNamespace::Legacy ||
        Roots[FinalRootIndex].Kind != InputRoot.Kind ||
        Roots[FinalRootIndex].TargetWireID != InputRoot.Target.ID)
      return false;
    ++FinalRootIndex;
  }
  return FinalRootIndex == Roots.size();
}

} // namespace

// Plan one safepoint's deopt pool. The pipeline is:
//   1. Index both node tables and validate the complete input (including
//      unreachable nodes) before any reachability decision.
//   2. Seed a worklist from the roots and mark every node reachable through
//      reference fields, redirecting overlaid scalar cells to their current
//      targets.
//   3. Bail out with fallback seeds when a reachable current node is
//      undescribable; the caller materializes it and retries.
//   4. Assign fresh dense wire IDs: legacy survivors first, then current
//      survivors, each in input order.
//   5. Assemble the final nodes/roots and detect whether the plan reproduces
//      the original bundle (NeedsRewrite), so a stable round can skip the
//      rewrite.
DeoptPoolPlannerResult
llvm::jeandle::pea::planDeoptPool(const DeoptPoolPlannerInput &Input) {
  // Index the legacy table by frontend wire ID, rejecting duplicates.
  DenseMap<uint32_t, unsigned> LegacyByWire;
  for (unsigned I = 0; I < Input.LegacyNodes.size(); ++I) {
    uint32_t WireID = Input.LegacyNodes[I].WireID;
    if (!LegacyByWire.try_emplace(WireID, I).second)
      return error(DeoptPoolPlannerErrorCode::DuplicateLegacyWireID, WireID);
  }

  // Index the current table by analysis-local ID, rejecting duplicates.
  DenseMap<CurrentDeoptNodeID, unsigned> CurrentByID;
  for (unsigned I = 0; I < Input.CurrentNodes.size(); ++I) {
    CurrentDeoptNodeID ID = Input.CurrentNodes[I].ID;
    if (!CurrentByID.try_emplace(ID, I).second)
      return error(DeoptPoolPlannerErrorCode::DuplicateCurrentNodeID, ID);
  }

  // Validate the complete input before doing reachability. In particular, a
  // malformed unreachable node is still rejected rather than being hidden by
  // pruning.
  DenseMap<DeoptPoolSemanticCellID, SemanticCellInfo> SemanticCells;
  auto AddSemanticCell = [&](DeoptPoolSemanticCellID Cell,
                             bool CanOverlay) -> DeoptPoolPlannerResult {
    if (Cell == InvalidDeoptPoolSemanticCellID)
      return error(DeoptPoolPlannerErrorCode::InvalidSemanticCellID, Cell);
    if (!SemanticCells.try_emplace(Cell, SemanticCellInfo{CanOverlay}).second)
      return error(DeoptPoolPlannerErrorCode::DuplicateSemanticCellID, Cell);
    return {};
  };
  auto ValidateRef =
      [&](const DeoptPoolNodeRef &Ref) -> DeoptPoolPlannerResult {
    if (!hasNode(Ref, LegacyByWire, CurrentByID))
      return error(DeoptPoolPlannerErrorCode::MissingNodeReference, Ref.ID);
    return {};
  };

  for (const LegacyDeoptPoolNode &Node : Input.LegacyNodes)
    for (const DeoptPoolFieldInput &Field : Node.Fields) {
      // A legacy scalar oop field is the only field shape an overlay may
      // reclassify.
      DeoptPoolPlannerResult CellResult =
          AddSemanticCell(Field.SemanticCell,
                          !Field.isReference() && Field.BasicType == T_OBJECT);
      if (CellResult.Error)
        return CellResult;
      if (Field.isReference()) {
        DeoptPoolPlannerResult RefResult = ValidateRef(Field.Target);
        if (RefResult.Error)
          return RefResult;
      }
    }

  for (const CurrentDeoptPoolNode &Node : Input.CurrentNodes)
    for (const DeoptPoolFieldInput &Field : Node.Fields) {
      // Current fields are newly emitted cells; they must not claim a source
      // bundle operand.
      if (Field.SemanticCell != InvalidDeoptPoolSemanticCellID)
        return error(DeoptPoolPlannerErrorCode::CurrentFieldHasSemanticCell,
                     Field.SemanticCell);
      if (Field.isReference()) {
        DeoptPoolPlannerResult RefResult = ValidateRef(Field.Target);
        if (RefResult.Error)
          return RefResult;
      }
    }

  for (const DeoptPoolRootInput &Root : Input.Roots) {
    // Any scalar root cell may be overlaid; the root's basic type lives in
    // the source bundle and is checked at lowering time.
    DeoptPoolPlannerResult CellResult =
        AddSemanticCell(Root.SemanticCell, !Root.isReference());
    if (CellResult.Error)
      return CellResult;
    if (Root.isReference()) {
      DeoptPoolPlannerResult RefResult = ValidateRef(Root.Target);
      if (RefResult.Error)
        return RefResult;
    }
  }

  // Admit only overlays that name a known overlayable cell, target a known
  // current node, and do not collide with another overlay.
  DenseMap<DeoptPoolSemanticCellID, CurrentDeoptNodeID> Overlays;
  for (const DeoptPoolScalarOverlay &Overlay : Input.Overlays) {
    auto Cell = SemanticCells.find(Overlay.SemanticCell);
    if (Cell == SemanticCells.end() || !Cell->second.CanOverlay ||
        !CurrentByID.count(Overlay.CurrentTarget) ||
        !Overlays.try_emplace(Overlay.SemanticCell, Overlay.CurrentTarget)
             .second)
      return error(DeoptPoolPlannerErrorCode::InvalidScalarOverlay,
                   Overlay.SemanticCell);
  }

  // Reachability worklist, seeded by every root whose final value is a
  // reference: already-reference roots and scalar roots reclassified by an
  // overlay. Purely scalar roots reach no node.
  SmallBitVector ReachableLegacy(Input.LegacyNodes.size());
  SmallBitVector ReachableCurrent(Input.CurrentNodes.size());
  SmallVector<DeoptPoolNodeRef, 16> Worklist;
  for (const DeoptPoolRootInput &Root : Input.Roots) {
    if (Overlays.count(Root.SemanticCell) || Root.isReference())
      Worklist.push_back(effectiveRootTarget(Root, Overlays));
  }

  while (!Worklist.empty()) {
    DeoptPoolNodeRef Ref = Worklist.pop_back_val();
    if (Ref.Namespace == DeoptPoolNodeNamespace::Legacy) {
      unsigned Index = LegacyByWire.lookup(Ref.ID);
      if (ReachableLegacy.test(Index))
        continue;
      ReachableLegacy.set(Index);
      // Follow both genuine reference fields and overlaid scalar oop fields.
      for (const DeoptPoolFieldInput &Field : Input.LegacyNodes[Index].Fields)
        if (Overlays.count(Field.SemanticCell) || Field.isReference())
          Worklist.push_back(effectiveFieldTarget(Field, Overlays));
      continue;
    }

    unsigned Index = CurrentByID.lookup(Ref.ID);
    if (ReachableCurrent.test(Index))
      continue;
    ReachableCurrent.set(Index);
    // Current fields have no source cells, hence no overlays; only genuine
    // references propagate reachability.
    for (const DeoptPoolFieldInput &Field : Input.CurrentNodes[Index].Fields)
      if (Field.isReference())
        Worklist.push_back(Field.Target);
  }

  // A reachable current node that cannot be described on the wire must be
  // materialized by the caller; report all such seeds and produce no plan.
  DeoptPoolPlannerResult Result;
  for (unsigned I = 0; I < Input.CurrentNodes.size(); ++I)
    if (ReachableCurrent.test(I) && !Input.CurrentNodes[I].Describable)
      Result.FallbackSeeds.push_back(Input.CurrentNodes[I].ID);
  if (!Result.FallbackSeeds.empty())
    return Result;

  // Dense wire IDs for the survivors: legacy nodes first (input order), then
  // current nodes (input order). Unreachable nodes keep the invalid ID and
  // are pruned from the plan.
  SmallVector<uint32_t, 8> LegacyFinalWire(Input.LegacyNodes.size(),
                                           InvalidDeoptPoolWireID);
  SmallVector<uint32_t, 8> CurrentFinalWire(Input.CurrentNodes.size(),
                                            InvalidDeoptPoolWireID);
  uint32_t NextWireID = 0;
  for (unsigned I = 0; I < Input.LegacyNodes.size(); ++I)
    if (ReachableLegacy.test(I))
      LegacyFinalWire[I] = NextWireID++;
  for (unsigned I = 0; I < Input.CurrentNodes.size(); ++I)
    if (ReachableCurrent.test(I))
      CurrentFinalWire[I] = NextWireID++;

  // Resolve one input field to its final form: an overlaid or already-
  // reference field becomes a T_OBJECT reference carrying the target's fresh
  // wire ID; any other field stays scalar and keeps its token.
  auto BuildField = [&](const DeoptPoolFieldInput &InputField,
                        bool AllowOverlay) -> FinalDeoptPoolField {
    FinalDeoptPoolField Field;
    Field.SemanticCell = InputField.SemanticCell;
    Field.Offset = InputField.Offset;
    Field.BasicType = InputField.BasicType;
    bool HasOverlay = AllowOverlay && Overlays.count(InputField.SemanticCell);
    if (HasOverlay || InputField.isReference()) {
      DeoptPoolNodeRef Target =
          HasOverlay ? DeoptPoolNodeRef::current(
                           Overlays.lookup(InputField.SemanticCell))
                     : InputField.Target;
      Field.IsReference = true;
      Field.BasicType = T_OBJECT;
      Field.TargetWireID = finalWireID(Target, LegacyByWire, CurrentByID,
                                       LegacyFinalWire, CurrentFinalWire);
    } else {
      Field.ScalarToken = InputField.ScalarToken;
    }
    return Field;
  };

  // Assemble the surviving legacy nodes, preserving input order and allowing
  // overlay redirection of their scalar oop fields.
  SmallVector<FinalDeoptPoolNode, 8> FinalNodes;
  for (unsigned I = 0; I < Input.LegacyNodes.size(); ++I) {
    if (!ReachableLegacy.test(I))
      continue;
    const LegacyDeoptPoolNode &InputNode = Input.LegacyNodes[I];
    FinalDeoptPoolNode Node;
    Node.WireID = LegacyFinalWire[I];
    Node.Klass = InputNode.Klass;
    Node.IsArray = InputNode.IsArray;
    Node.IsBoxed = InputNode.IsBoxed;
    Node.Origin = DeoptPoolNodeOrigin::Legacy;
    Node.LegacySourceIndex = I;
    for (const DeoptPoolFieldInput &Field : InputNode.Fields)
      Node.Fields.push_back(BuildField(Field, /*AllowOverlay=*/true));
    FinalNodes.push_back(std::move(Node));
  }

  // Append the surviving current nodes, preserving input order. Their fields
  // are newly emitted and cannot be overlaid.
  SmallVector<CurrentDeoptNodeID, 8> CurrentMembers;
  for (unsigned I = 0; I < Input.CurrentNodes.size(); ++I) {
    if (!ReachableCurrent.test(I))
      continue;
    const CurrentDeoptPoolNode &InputNode = Input.CurrentNodes[I];
    FinalDeoptPoolNode Node;
    Node.WireID = CurrentFinalWire[I];
    Node.Klass = InputNode.Klass;
    Node.IsArray = InputNode.IsArray;
    Node.IsBoxed = InputNode.IsBoxed;
    Node.Origin = DeoptPoolNodeOrigin::Current;
    Node.CurrentID = InputNode.ID;
    for (const DeoptPoolFieldInput &Field : InputNode.Fields)
      Node.Fields.push_back(BuildField(Field, /*AllowOverlay=*/false));
    FinalNodes.push_back(std::move(Node));
    CurrentMembers.push_back(InputNode.ID);
  }

  // Keep only roots whose final value is a reference, in input order.
  SmallVector<FinalDeoptPoolRoot, 8> FinalRoots;
  for (const DeoptPoolRootInput &InputRoot : Input.Roots) {
    if (!Overlays.count(InputRoot.SemanticCell) && !InputRoot.isReference())
      continue;
    DeoptPoolNodeRef Target = effectiveRootTarget(InputRoot, Overlays);
    FinalRoots.push_back({InputRoot.SemanticCell, InputRoot.Kind,
                          finalWireID(Target, LegacyByWire, CurrentByID,
                                      LegacyFinalWire, CurrentFinalWire)});
  }

  // A plan identical to the original bundle needs no rewrite; this is the
  // fixpoint signal that lets a stable second planning round stop.
  bool NeedsRewrite = !isSemanticNoOp(Input, Overlays, FinalNodes, FinalRoots);
  Result.Plan = DeoptPoolPlannerAccess::create(
      std::move(FinalNodes), std::move(FinalRoots), std::move(CurrentMembers),
      NeedsRewrite);
  return Result;
}
