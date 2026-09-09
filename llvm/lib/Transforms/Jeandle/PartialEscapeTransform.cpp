//===- PartialEscapeTransform.cpp - PEA (transform pass) ------------------===//
//
// Copyright (c) 2026, the Jeandle-LLVM Authors. All Rights Reserved.
//
// Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM
// Exceptions. See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
// Consume the PEAResult from PartialEscapeAnalysis and apply its effects in
// three ordered phases. Ordinary value/state mutations run first, the atomic
// deopt-pool rewrite observes their final SSA replacements next, and
// allocation/CFG deletion runs last.
//
//   Phase 1 (Ordinary): ReplaceLoad, ReplaceCall, EliminateStore,
//   Materialize, CreatePHI.
//
//   Phase 2 (DeoptPool): one atomic whole-pool rewrite per surviving
//   safepoint.
//
//   Phase 3 (CfgKill): EliminateAllocation rewrites a NeverEscapes invoke
//   allocation into an unconditional branch (dropping the unwind edge) or
//   erases a plain call allocation.
//
// Materialization model: a PartiallyEscapes VO materializes by replaying its
// tracked field stores and re-emitting its surviving monitorenters onto its
// real identity. For an ordinary VO this is its ORIGINAL allocation
// (OrigAlloc = VObj.AllocationCall); for a prepared synthetic Case-C VO (one
// synthetic VO merged from a pointer PHI's distinct but compatible virtual
// incomings; see PartialEscapeAnalysis.cpp) it is SyntheticPhi. Both dominate
// their escape points. Ordinary PartiallyEscapes
// allocations are kept alive, so their original allocation-site deopt bundles
// remain intact. NeverEscapes VOs are eliminated (OrigAlloc erased) and
// described by a deopt-bundle descriptor (HotSpot reallocs at deopt). The
// InsertBefore eager-update hook (relocateDependentMaterializes) is retained
// because a sibling fold can still erase E.InsertBefore.
//
// When several objects escape at one escape point, their interleaved locks on
// the runtime lock stack MUST be re-emitted as ONE globally depth-sorted list
// (computeEscapePointLocks), emitted once by the highest-SeqNo materialize at
// that point, each receiver resolved to the sibling's original/materialized
// replay receiver via MaterializedReceiverOf.
// Per-object lock emission would mis-order re-entrant interleaved lock stacks.
//
// After the three phases: ConstantFoldTerminator, a trivial-PHI fold, a
// dead-code sweep, and EliminateUnreachableBlocks.
//
//===----------------------------------------------------------------------===//

#include "llvm/Transforms/Jeandle/PartialEscapeTransform.h"

#include "llvm/ADT/PostOrderIterator.h"
#include "llvm/ADT/STLExtras.h"
#include "llvm/ADT/SmallPtrSet.h"
#include "llvm/ADT/SmallVector.h"
#include "llvm/Analysis/Jeandle/DeoptPoolBundleLowering.h"
#include "llvm/Analysis/Jeandle/PartialEscape.h"
#include "llvm/Analysis/Jeandle/PartialEscapeAnalysis.h"
#include "llvm/Analysis/Jeandle/PartialEscapeUtils.h"
#include "llvm/IR/BasicBlock.h"
#include "llvm/IR/CFG.h"
#include "llvm/IR/Constants.h"
#include "llvm/IR/DataLayout.h"
#include "llvm/IR/DerivedTypes.h"
#include "llvm/IR/Dominators.h"
#include "llvm/IR/EHPersonalities.h"
#include "llvm/IR/Function.h"
#include "llvm/IR/IRBuilder.h"
#include "llvm/IR/InstrTypes.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/IntrinsicInst.h"
#include "llvm/IR/Jeandle/Attributes.h"
#include "llvm/IR/Jeandle/Metadata.h"
#include "llvm/IR/Metadata.h"
#include "llvm/IR/Module.h"
#include "llvm/IR/Verifier.h"
#include "llvm/Support/ErrorHandling.h"
#include "llvm/Support/MathExtras.h"
#include "llvm/Support/raw_ostream.h"
#include "llvm/Transforms/Jeandle/JeandleTransformUtils.h"
#include "llvm/Transforms/Utils/BasicBlockUtils.h"
#include "llvm/Transforms/Utils/Local.h"

#include <algorithm>

using namespace llvm;

// A merge materialization replays on exactly one incoming edge of the merge,
// but an LLVM predecessor terminator denotes every outgoing edge. A
// Source->Target edge whose source has multiple successors therefore needs a
// dedicated edge block that the replay plan can target. All MaterializeEffects
// for an edge move together: field stores and monitor replay have identical
// control dependence.
static bool splitReplayEdges(jeandle::PEAResult &Result) {
  struct EdgePlan {
    BasicBlock *Source;
    BasicBlock *Target;
    unsigned SuccessorIndex;
    uint32_t MinSeqNo;
    SmallVector<jeandle::MaterializeEffect *, 4> Effects;
  };

  SmallVector<EdgePlan, 4> Plans;
  for (auto &KV : Result.BlockEffects)
    for (jeandle::Effect &E : KV.second) {
      auto *ME = dyn_cast<jeandle::MaterializeEffect>(&E);
      if (!ME || !ME->ReplaySource || !ME->ReplayTarget)
        continue;
      // Reuse-OrigAlloc materialization can be state-only: with no fields or
      // monitors to replay, applying the effect emits no instruction. Its
      // target-local analysis state is still required, but splitting the CFG
      // would create an empty block with no runtime control dependence to
      // preserve.
      if (ME->FieldEntries.empty() && ME->Locks.empty())
        continue;
      EdgePlan *Plan = nullptr;
      for (EdgePlan &Candidate : Plans)
        if (Candidate.Source == ME->ReplaySource &&
            Candidate.Target == ME->ReplayTarget) {
          Plan = &Candidate;
          break;
        }
      if (!Plan) {
        Instruction *Term = ME->ReplaySource->getTerminator();
        unsigned SuccessorIndex = Term->getNumSuccessors();
        for (unsigned I = 0; I < Term->getNumSuccessors(); ++I)
          if (Term->getSuccessor(I) == ME->ReplayTarget) {
            SuccessorIndex = I;
            break;
          }
        assert(SuccessorIndex != Term->getNumSuccessors() &&
               "replay source must reach its recorded target");
        Plans.push_back({ME->ReplaySource,
                         ME->ReplayTarget,
                         SuccessorIndex,
                         ME->SeqNo,
                         {}});
        Plan = &Plans.back();
      }
      Plan->MinSeqNo = std::min(Plan->MinSeqNo, ME->SeqNo);
      Plan->Effects.push_back(ME);
    }

  // BlockEffects is a DenseMap. Use the analyzer's function-wide monotonic
  // effect sequence to make block creation, naming, RPO, and trace IDs stable.
  llvm::sort(Plans, [](const EdgePlan &A, const EdgePlan &B) {
    return A.MinSeqNo < B.MinSeqNo;
  });

  // Landingpad predecessor splitting clones the landingpad and may synthesize
  // intermediate PHIs for the selected and remaining unwind predecessors.
  // Insert analysis-owned field PHIs first so LLVM's canonical utility updates
  // them together with every PHI already present in the IR.
  SmallPtrSet<BasicBlock *, 4> LandingPadTargets;
  for (const EdgePlan &Plan : Plans) {
    SmallPtrSet<BasicBlock *, 4> Successors;
    for (BasicBlock *Succ : successors(Plan.Source))
      Successors.insert(Succ);
    if (Successors.size() > 1 && Plan.Target->isLandingPad())
      LandingPadTargets.insert(Plan.Target);
  }
  if (!LandingPadTargets.empty()) {
    SmallVector<jeandle::CreatePHIEffect *, 8> DeferredPhis;
    for (auto &KV : Result.BlockEffects)
      for (jeandle::Effect &E : KV.second) {
        auto *PE = dyn_cast<jeandle::CreatePHIEffect>(&E);
        if (PE && LandingPadTargets.count(PE->Block))
          DeferredPhis.push_back(PE);
      }
    llvm::sort(DeferredPhis, [](const jeandle::CreatePHIEffect *A,
                                const jeandle::CreatePHIEffect *B) {
      return A->SeqNo < B->SeqNo;
    });
    for (jeandle::CreatePHIEffect *PE : DeferredPhis) {
      PHINode *Phi = PE->PhiInst;
      assert(Phi && !Phi->getParent() &&
             "deferred field PHI must be unparented before CFG normalization");
      Phi->insertBefore(PE->Block->getFirstNonPHIIt());
      assert(PE->PHIIncomingValues.size() == PE->PHIIncomingBlocks.size());
      for (unsigned I = 0; I < PE->PHIIncomingValues.size(); ++I)
        Phi->addIncoming(PE->PHIIncomingValues[I], PE->PHIIncomingBlocks[I]);
    }
  }

  // Index unparented CreatePHIEffects by their target block so each split-edge
  // plan finds its PHIs by lookup instead of re-scanning all BlockEffects. The
  // landingpad insertion above has already parented the landingpad PHIs, and
  // the plan loop below only renames PHI incoming blocks and MaterializeEffect
  // targets — never a CreatePHIEffect's Block nor its parent — so this index
  // stays valid for the whole loop.
  DenseMap<BasicBlock *, SmallVector<jeandle::CreatePHIEffect *, 2>>
      UnparentedPhisByBlock;
  for (auto &KV : Result.BlockEffects)
    for (jeandle::Effect &E : KV.second) {
      auto *PE = dyn_cast<jeandle::CreatePHIEffect>(&E);
      if (PE && !PE->PhiInst->getParent())
        UnparentedPhisByBlock[PE->Block].push_back(PE);
    }

  bool Changed = false;
  for (EdgePlan &Plan : Plans) {
    // CFG utilities preserve a terminator's successor indices while replacing
    // their destinations. A prior landingpad split may have redirected this
    // unwind index to a cloned landingpad (including through several earlier
    // splits), so the recorded index is the exact current physical target.
    Instruction *Term = Plan.Source->getTerminator();
    assert(Plan.SuccessorIndex < Term->getNumSuccessors());
    BasicBlock *CurrentTarget = Term->getSuccessor(Plan.SuccessorIndex);

    SmallPtrSet<BasicBlock *, 4> DistinctSuccessors;
    for (BasicBlock *Succ : successors(Plan.Source)) {
      DistinctSuccessors.insert(Succ);
    }
    if (DistinctSuccessors.size() <= 1)
      continue;

    assert(!isa<IndirectBrInst>(Plan.Source->getTerminator()) &&
           !isa<CallBrInst>(Plan.Source->getTerminator()) &&
           CurrentTarget->canSplitPredecessors() &&
           "analysis must keep unsplittable replay edges real");
    BasicBlock *Edge =
        SplitBlockPredecessors(CurrentTarget, {Plan.Source}, ".pea.replay");
    assert(Edge && Edge->getTerminator() &&
           "splittable replay edge must produce an insertion block");

    // Landingpad-targeted deferred PHIs were inserted above and therefore were
    // rewritten by SplitBlockPredecessors itself. Ordinary targets can still
    // own unparented field-value PHIs; keep their recorded incoming blocks
    // synchronized with the normalized CFG. replaceSuccessorWith redirects
    // every duplicate edge from Source (e.g. switch cases sharing a
    // destination) onto the single new Edge->CurrentTarget edge, so duplicate
    // Source slots of such PHIs collapse into one Edge slot. Collapsed slots
    // carry the same value: they were merged from the same predecessor state.
    auto Found = UnparentedPhisByBlock.find(CurrentTarget);
    if (Found != UnparentedPhisByBlock.end())
      for (jeandle::CreatePHIEffect *PE : Found->second) {
        int Kept = -1;
        for (unsigned I = 0; I < PE->PHIIncomingBlocks.size();) {
          if (PE->PHIIncomingBlocks[I] != Plan.Source) {
            ++I;
            continue;
          }
          if (Kept < 0) {
            PE->PHIIncomingBlocks[I] = Edge;
            Kept = (int)I++;
            continue;
          }
          Value *KeptV = PE->PHIIncomingValues[Kept];
          Value *DroppedV = PE->PHIIncomingValues[I];
          assert(KeptV == DroppedV &&
                 "duplicate edges from one pred carry the same merged value");
          PE->PHIIncomingBlocks.erase(PE->PHIIncomingBlocks.begin() + I);
          PE->PHIIncomingValues.erase(PE->PHIIncomingValues.begin() + I);
        }
      }

    for (jeandle::MaterializeEffect *ME : Plan.Effects) {
      // Keep ownership in the original source bucket so EffectList references
      // remain stable. Block and InsertBefore describe the normalized semantic
      // location; applyMaterialize inserts through InsertBefore rather than
      // assuming the bucket key is the physical block.
      ME->ReplaySource = Edge;
      ME->Block = Edge;
      ME->setInsertBefore(Edge->getTerminator());
    }
    Changed = true;
  }
  return Changed;
}

// One expected operation in an existing replay suffix: either a field store
// (Receiver/StoredValue/Offset) or a re-emitted monitorenter (LockCallee with
// LockArgs, whose first element is the receiver). Used only by
// matchExistingReplaySuffix.
struct ExpectedReplayOperation {
  enum class Kind : uint8_t { Store, Lock } K;
  Value *Receiver = nullptr;
  Value *StoredValue = nullptr;
  int64_t Offset = 0;
  Function *LockCallee = nullptr;
  SmallVector<Value *, 4> LockArgs;
};

// The replayed field stores of one materialized object, matched as one
// contiguous unit. HasDistinctRealAllocation records that Receiver is the
// object's own OrigAlloc (not a shared synthetic PHI), in which case the
// group may match in permuted order against sibling groups (see
// matchExistingReplaySuffix).
struct ExpectedReplayFieldGroup {
  Value *Receiver = nullptr;
  bool HasDistinctRealAllocation = false;
  SmallVector<ExpectedReplayOperation, 4> Fields;
};

// The concrete value a replay store must write for a field entry, or null
// when the entry carries no materializable value.
static Value *
materializedFieldValue(const jeandle::MaterializeEffect::FieldEntry &FE) {
  if (FE.Value.isScalar())
    return FE.Value.getScalar();
  if (FE.Value.isMaterializedRef())
    return FE.Value.getMaterialized();
  return nullptr;
}

// The nearest non-debug instruction before I in its block, or null when I is
// the first such instruction.
static Instruction *previousNonDebugInstruction(Instruction *I) {
  for (I = I->getPrevNode(); I; I = I->getPrevNode())
    if (!I->isDebugOrPseudoInst())
      return I;
  return nullptr;
}

// True when GEP is exactly the field-address GEP the replay emitter produces
// for Op feeding Store: an inbounds i8 GEP on the receiver with one constant
// index equal to the field offset, a single use (Store), placed immediately
// before Store, carrying no non-debug metadata.
static bool isCanonicalReplayGEP(GetElementPtrInst &GEP,
                                 const ExpectedReplayOperation &Op,
                                 StoreInst &Store) {
  if (GEP.getPointerOperand() != Op.Receiver ||
      GEP.getSourceElementType() != Type::getInt8Ty(GEP.getContext()) ||
      GEP.getNumIndices() != 1 || GEP.getParent() != Store.getParent() ||
      !GEP.hasOneUse() || *GEP.user_begin() != &Store ||
      previousNonDebugInstruction(&Store) != &GEP ||
      GEP.hasMetadataOtherThanDebugLoc())
    return false;

  auto *Index = dyn_cast<ConstantInt>(*GEP.idx_begin());
  if (!Index || Index->getBitWidth() != 64 ||
      Index->getSExtValue() != Op.Offset)
    return false;

  // IRBuilder::CreateInBoundsGEP emits the inbounds/nusw combination.  The
  // canonical pipeline between two PEA rounds may additionally prove nuw for
  // this constant field offset; no other flag combination is emitted or
  // inferred by that pipeline.
  GEPNoWrapFlags Flags = GEP.getNoWrapFlags();
  GEPNoWrapFlags InBounds = GEPNoWrapFlags::inBounds();
  return Flags == InBounds ||
         Flags == (InBounds | GEPNoWrapFlags::noUnsignedWrap());
}

// Reject matching only the tail of a longer sequence that still looks like
// replay for the same materialized receivers.  Being conservative here costs
// one rewrite round, whereas retaining an extra source operation can make the
// fixed-point depend on an accidental instruction boundary.
static bool isReplayLikePrefix(Instruction *I,
                               ArrayRef<ExpectedReplayOperation> Expected,
                               const DataLayout &DL) {
  if (!I)
    return false;

  if (auto *Store = dyn_cast<StoreInst>(I)) {
    int64_t Offset = 0;
    bool NonConstant = false;
    Value *Base = jeandle::pea::stripPointerCastsAndOffsets(
        Store->getPointerOperand(), DL, &Offset, &NonConstant);
    if (NonConstant)
      return false;
    for (const ExpectedReplayOperation &Op : Expected)
      if (Op.Receiver == Base)
        return true;
    return false;
  }

  auto *Call = dyn_cast<CallInst>(I);
  if (!Call || Call->arg_empty())
    return false;
  for (const ExpectedReplayOperation &Op : Expected)
    if (Op.K == ExpectedReplayOperation::Kind::Lock &&
        Call->getCalledFunction() == Op.LockCallee &&
        Call->getArgOperand(0) == Op.Receiver)
      return true;
  return false;
}

// A later outer PEA round sees the stores and monitorenters emitted by the
// preceding round as ordinary virtualizable operations. Replacing an identical
// replay sequence would mutate the IR forever without making semantic
// progress. Match the contiguous semantic suffix exactly within every object's
// field group and within the final lock list. Complete field groups belonging
// to distinct real allocations may appear in a different order: their objects
// are still unpublished, so those groups cannot alias or be observed between
// stores. Synthetic or repeated receivers retain strict SeqNo order.
static bool matchExistingReplaySuffix(
    Instruction *InsertBefore, ArrayRef<jeandle::MaterializeEffect *> Effects,
    jeandle::PEAResult &Result,
    SmallVectorImpl<Instruction *> &MatchingInstructions) {
  SmallVector<ExpectedReplayOperation, 16> Expected;
  SmallVector<ExpectedReplayFieldGroup, 4> FieldGroups;
  SmallVector<ExpectedReplayOperation, 4> ExpectedLocks;
  SmallVector<jeandle::MaterializeEffect *, 4> Ordered(Effects);
  llvm::sort(Ordered, [](const jeandle::MaterializeEffect *A,
                         const jeandle::MaterializeEffect *B) {
    return A->SeqNo < B->SeqNo;
  });

  auto appendLock = [&](Value *Receiver, Function *Callee,
                        ArrayRef<WeakTrackingVH> NonReceiverArgs) {
    ExpectedReplayOperation Op;
    Op.K = ExpectedReplayOperation::Kind::Lock;
    Op.LockCallee = Callee;
    Op.LockArgs.push_back(Receiver);
    for (Value *Arg : NonReceiverArgs)
      Op.LockArgs.push_back(Arg);
    ExpectedLocks.push_back(Op);
    Expected.push_back(std::move(Op));
  };

  const jeandle::LockReplayBatch *ReplayBatch =
      Result.getLockReplayBatch(InsertBefore);
  for (jeandle::MaterializeEffect *Effect : Ordered) {
    if (!Effect->hasMutationOwner())
      return false;
    jeandle::ObjectID MutationOwner = Effect->getMutationOwner();
    ExpectedReplayFieldGroup Group;
    Group.Receiver = Effect->Target;
    if (MutationOwner < Result.VirtualObjects.size()) {
      const jeandle::VirtualObject &VObj =
          *Result.VirtualObjects[MutationOwner];
      auto *Allocation = dyn_cast_or_null<CallBase>((Value *)Effect->Target);
      Group.HasDistinctRealAllocation =
          !VObj.IsSynthetic && Allocation &&
          (Value *)VObj.AllocationCall == (Value *)Allocation &&
          jeandle::pea::isJeandleAllocation(Allocation);
    }
    for (const auto &Field : Effect->FieldEntries) {
      Value *Stored = materializedFieldValue(Field);
      Value *Receiver = Effect->Target;
      if (!Stored || !Receiver)
        return false;
      ExpectedReplayOperation Op{ExpectedReplayOperation::Kind::Store,
                                 Receiver,
                                 Stored,
                                 Field.Offset,
                                 nullptr,
                                 {}};
      Group.Fields.push_back(Op);
      Expected.push_back(std::move(Op));
    }
    FieldGroups.push_back(std::move(Group));

    if (ReplayBatch && Effect->SeqNo == ReplayBatch->EmitterSeqNo) {
      for (const jeandle::MergedLock &Lock : ReplayBatch->Locks) {
        Value *Receiver =
            Lock.SourceEffect ? (Value *)Lock.SourceEffect->Target : nullptr;
        if (!Receiver || !Lock.Callee)
          return false;
        appendLock(Receiver, Lock.Callee, Lock.NonReceiverArgs);
      }
    }
  }

  const DataLayout &DL = InsertBefore->getModule()->getDataLayout();
  SmallVector<Instruction *, 16> MatchedReverse;
  Instruction *Cursor = previousNonDebugInstruction(InsertBefore);
  auto matchLock = [&](const ExpectedReplayOperation &Op) {
    // A replay lock is identified by the structural form PEA itself emits: the
    // same callee, the Hotspot_JIT calling convention, no operand bundles, a
    // non-tail call, and identical operands sitting in the contiguous replay
    // suffix before the escape point. The emitter adds no call-site attributes
    // or metadata, so any present on the candidate were added by other passes
    // (e.g. InstCombine strengthening operands between outer iterations) and
    // are intentionally ignored — matching on them would reject PEA's own
    // replay after such a strengthening and force a delete/rebuild churn every
    // round.
    auto *Call = dyn_cast_or_null<CallInst>(Cursor);
    if (!Call || Call->getCalledFunction() != Op.LockCallee ||
        Call->getCallingConv() != CallingConv::Hotspot_JIT ||
        Call->hasOperandBundles() || Call->arg_size() != Op.LockArgs.size() ||
        Call->getTailCallKind() != CallInst::TCK_None)
      return false;
    for (unsigned Arg = 0; Arg < Op.LockArgs.size(); ++Arg)
      if (Call->getArgOperand(Arg) != Op.LockArgs[Arg])
        return false;
    MatchedReverse.push_back(Call);
    Cursor = previousNonDebugInstruction(Call);
    return true;
  };
  for (const ExpectedReplayOperation &Op : llvm::reverse(ExpectedLocks))
    if (!matchLock(Op))
      return false;

  auto matchFieldGroup =
      [&](const ExpectedReplayFieldGroup &Group, Instruction *Start,
          SmallVectorImpl<Instruction *> &Matched, Instruction *&Before) {
        Instruction *At = Start;
        SmallVector<Instruction *, 8> Candidate;
        for (const ExpectedReplayOperation &Op : llvm::reverse(Group.Fields)) {
          auto *Store = dyn_cast_or_null<StoreInst>(At);
          if (!Store || Store->getValueOperand() != Op.StoredValue ||
              Store->isVolatile() || !Store->isAtomic() ||
              Store->getSyncScopeID() != SyncScope::System ||
              Store->getOrdering() != AtomicOrdering::Unordered ||
              Store->hasMetadataOtherThanDebugLoc())
            return false;
          auto *GEP = dyn_cast<GetElementPtrInst>(Store->getPointerOperand());
          if (!GEP || !isCanonicalReplayGEP(*GEP, Op, *Store))
            return false;
          TypeSize StoreSize = DL.getTypeStoreSize(Op.StoredValue->getType());
          if (StoreSize.isScalable())
            return false;
          uint64_t FixedStoreSize = StoreSize.getFixedValue();
          if (Store->getAlign() !=
              Align(PowerOf2Ceil(FixedStoreSize ? FixedStoreSize : 1)))
            return false;

          Candidate.push_back(Store);
          Candidate.push_back(GEP);
          At = previousNonDebugInstruction(GEP);
        }
        Matched.append(Candidate.begin(), Candidate.end());
        Before = At;
        return true;
      };

  // Collect the non-empty field groups and decide whether whole groups may
  // match in permuted order. Permutation is allowed only when every non-empty
  // group replays onto its object's own distinct real allocation and no
  // receiver repeats: those objects are still unpublished, so their store
  // groups cannot alias or be observed between stores, and any group order in
  // the IR is equivalent. Otherwise groups must match in strict reverse
  // emission order.
  SmallVector<unsigned, 4> NonEmptyGroups;
  DenseMap<Value *, unsigned> GroupForReceiver;
  bool MayPermuteGroups = true;
  for (unsigned I = 0; I < FieldGroups.size(); ++I) {
    const ExpectedReplayFieldGroup &Group = FieldGroups[I];
    if (Group.Fields.empty())
      continue;
    NonEmptyGroups.push_back(I);
    MayPermuteGroups &= Group.HasDistinctRealAllocation &&
                        GroupForReceiver.try_emplace(Group.Receiver, I).second;
  }

  if (MayPermuteGroups && NonEmptyGroups.size() > 1) {
    // Permuted matching: walk the IR backward from the escape point, identify
    // the group owning the current store's receiver, and consume that whole
    // group. Each group is consumed at most once.
    SmallVector<uint8_t, 4> Consumed(FieldGroups.size(), 0);
    for (unsigned Remaining = NonEmptyGroups.size(); Remaining; --Remaining) {
      auto *Store = dyn_cast_or_null<StoreInst>(Cursor);
      auto *GEP = Store
                      ? dyn_cast<GetElementPtrInst>(Store->getPointerOperand())
                      : nullptr;
      if (!GEP)
        return false;
      auto It = GroupForReceiver.find(GEP->getPointerOperand());
      if (It == GroupForReceiver.end() || Consumed[It->second])
        return false;
      unsigned Match = It->second;
      SmallVector<Instruction *, 8> MatchedGroup;
      Instruction *MatchedBefore = nullptr;
      if (!matchFieldGroup(FieldGroups[Match], Cursor, MatchedGroup,
                           MatchedBefore))
        return false;
      Consumed[Match] = true;
      MatchedReverse.append(MatchedGroup.begin(), MatchedGroup.end());
      Cursor = MatchedBefore;
    }
  } else {
    // Strict matching: groups must appear in exact reverse emission order.
    for (unsigned I : llvm::reverse(NonEmptyGroups)) {
      SmallVector<Instruction *, 8> MatchedGroup;
      Instruction *Before = nullptr;
      if (!matchFieldGroup(FieldGroups[I], Cursor, MatchedGroup, Before))
        return false;
      MatchedReverse.append(MatchedGroup.begin(), MatchedGroup.end());
      Cursor = Before;
    }
  }

  if (!Expected.empty() && isReplayLikePrefix(Cursor, Expected, DL))
    return false;

  MatchingInstructions.append(MatchedReverse.rbegin(), MatchedReverse.rend());
  return true;
}

// Erase a NeverEscapes allocation. An invoke is rewritten to an unconditional
// branch to its normal destination, dropping the unwind edge; a plain call is
// erased outright. Any remaining uses are poisoned first.
static bool eraseAllocation(Instruction *Target) {
  assert(Target && "EliminateAllocation target must be non-null");

  if (auto *II = dyn_cast<InvokeInst>(Target)) {
    // The transform is the last line of defense: dropping the unwind edge is
    // only sound because the analyzer proved this allocation never observably
    // escapes, and a Jeandle allocation intrinsic's exception edge handles
    // OOM only (unobservable — re-thrown identically by the materialized
    // invoke or, for NeverEscapes, never taken). Assert the analyzer's
    // NeverEscapes contract so a future misclassification of a side-effecting
    // invoke as eliminable fails loudly instead of silently miscompiling.
    assert(jeandle::pea::isJeandleAllocation(II) &&
           "EliminateAllocation may only drop the unwind edge of a Jeandle "
           "allocation intrinsic (OOM-only, unobservable throw)");
    BasicBlock *Normal = II->getNormalDest();
    BasicBlock *Unwind = II->getUnwindDest();
    BasicBlock *Parent = II->getParent();
    assert(Normal != Unwind &&
           "PEA drops an allocation invoke's unwind edge; "
           "normal and unwind dests must differ (a Jeandle allocation's unwind "
           "is an OOM handler distinct from its normal successor)");

    // Null out any remaining uses before erasing.
    if (!II->use_empty())
      II->replaceAllUsesWith(PoisonValue::get(II->getType()));

    // Remove the unwind edge: update any PHIs in the unwind block so they
    // forget the predecessor we're about to drop.
    Unwind->removePredecessor(Parent, /*KeepOneInputPHIs=*/true);

    // Replace the invoke with an unconditional branch to the normal dest.
    BranchInst::Create(Normal, Parent);
    II->eraseFromParent();
    return true;
  }

  if (auto *CI = dyn_cast<CallInst>(Target)) {
    // Same NeverEscapes contract as the invoke branch above (a call-form
    // allocation has no unwind edge to drop, but the eliminability guarantee
    // is identical).
    assert(jeandle::pea::isJeandleAllocation(CI) &&
           "EliminateAllocation target must be a Jeandle allocation intrinsic");
    if (!CI->use_empty())
      CI->replaceAllUsesWith(PoisonValue::get(CI->getType()));
    CI->eraseFromParent();
    return true;
  }

  return false;
}

// Eager-update hook: call this BEFORE erasing `Dying` from IR. Re-aims every
// Materialize whose InsertBefore == Dying to `Next` (the in-block normal-flow
// successor — for a non-terminator Target->getNextNode(); for an invoke
// terminator, the `br` created by BranchInst::Create, captured as
// II->getNextNode() after Create but before erase). This keeps the
// WeakTrackingVH alive so applyMaterialize never sees a null InsertBefore.
// Still required because a Materialize's InsertBefore can be a folded JavaOp
// invoke terminator that a sibling ReplaceCall erases in the same block bucket
// (lower SeqNo). Re-aiming to the successor (same program point, same block)
// is sound: every replayed field value that dominated the erased instruction
// also dominates its in-block successor.
// Re-indexes each dependent into Next's bucket so a future erase of Next
// chains correctly.
static void relocateDependentMaterializes(
    DenseMap<Instruction *, SmallVector<jeandle::MaterializeEffect *, 4>>
        &Dependents,
    Instruction *Dying, Instruction *Next) {
  // Callers always pass a non-null Next: a non-terminator load/store/call's
  // getNextNode(), or the fresh `br` created immediately before erasing an
  // invoke terminator (II->getNextNode() after BranchInst::Create). Assert the
  // contract so a future caller that would pass null fails loudly instead of
  // silently leaving a dependent Materialize keyed on a soon-null InsertBefore
  // (which applyMaterialize would only catch later via its own assert).
  assert(Next && "Next must be non-null: callers pass Target->getNextNode() "
                 "(non-terminator load/store/call) or the fresh `br` created "
                 "before erasing an invoke terminator");
  if (Next == Dying) // defensive: identity case, nothing to relocate
    return;
  auto It = Dependents.find(Dying);
  if (It == Dependents.end())
    return;
  // Move the bucket out and erase Dying's entry BEFORE any insert: inserting
  // into Dependents[Next] below could rehash and invalidate `It`.
  SmallVector<jeandle::MaterializeEffect *, 4> Bucket = std::move(It->second);
  Dependents.erase(It);
  auto &NextBucket = Dependents[Next];
  for (jeandle::MaterializeEffect *M : Bucket) {
    M->setInsertBefore(Next);
    NextBucket.push_back(M);
  }
}

// Splice an analyzer-built UNPARENTED instruction — and every unparented
// instruction in its operand chain — into IR immediately before IP, in
// postorder so each operand is parented before its user. PHINodes are
// treated as leaves (splicing a PHI mid-block is illegal; analyzer-built
// PHIs are owned by CreatePHI effects). No-op for values already in IR, for
// PHIs, and for non-instructions. Used when an effect's recorded value was
// built by the analyzer (e.g. a pea.coerce bitcast) but was never spliced —
// e.g. the ReplaceLoad that owned it was dropped by dropEffectsFor.
static void spliceUnparentedAt(Instruction *IP, Value *V) {
  auto *RI = dyn_cast_or_null<Instruction>(V);
  if (!RI || isa<PHINode>(RI) || RI->getParent())
    return;
  SmallPtrSet<Instruction *, 4> Visited;
  SmallVector<Instruction *, 4> PostOrder;
  struct Frame {
    Instruction *I;
    unsigned NextOpIdx;
  };
  SmallVector<Frame, 4> Frames;
  Visited.insert(RI);
  Frames.push_back({RI, 0});
  while (!Frames.empty()) {
    Frame &Top = Frames.back();
    if (Top.NextOpIdx < Top.I->getNumOperands()) {
      Value *Op = Top.I->getOperand(Top.NextOpIdx++);
      if (auto *OpI = dyn_cast<Instruction>(Op)) {
        if (OpI->getParent() == nullptr && !isa<PHINode>(OpI) &&
            Visited.insert(OpI).second) {
          Frames.push_back({OpI, 0});
        }
      }
    } else {
      PostOrder.push_back(Top.I);
      Frames.pop_back();
    }
  }
  for (Instruction *I : PostOrder)
    if (I->getParent() == nullptr)
      I->insertBefore(IP->getIterator());
}

// Emit the materialization sequence for a single Materialize effect: replay
// tracked field stores and re-emit surviving monitorenters onto the real
// receiver immediately before the escape point (see the file header). The
// downstream GC-statepoint pipeline (PEA → InsertGCBarriers → ... →
// RewriteStatepointsForGC) wraps ordinary allocation invokes with
// gc.statepoint/gc.result/gc.relocate; every replay receiver dominates its
// emitted stores. See `partial-escape/310_full_pipeline_statepoint.ll`.
static bool applyMaterialize(Function &F, const jeandle::PEAResult &Result,
                             const jeandle::MaterializeEffect &E,
                             DenseMap<const jeandle::MaterializeEffect *,
                                      Value *> &MaterializedReceiverOf,
                             const DenseMap<const jeandle::MaterializeEffect *,
                                            Instruction *> &OrigInsertBefore) {
  assert(E.hasMutationOwner());
  assert(E.Target && "Materialize effect must carry a replay receiver");

  jeandle::VirtualObject &VObj = *Result.VirtualObjects[E.getMutationOwner()];
  CallBase *OrigAlloc = cast_or_null<CallBase>((Value *)VObj.AllocationCall);
  Value *MatVal = E.Target;
  if (VObj.IsSynthetic)
    assert(MatVal == VObj.SyntheticPhi &&
           "synthetic materialization must replay onto SyntheticPhi");
  else
    assert((Value *)OrigAlloc == MatVal &&
           "ordinary materialization must replay onto OrigAlloc");

  Module *M = F.getParent();
  LLVMContext &Ctx = M->getContext();
  const DataLayout &DL = M->getDataLayout();

  // applyMaterialize is reached only for PartiallyEscapes VOs (NeverEscapes go
  // to EliminateAllocation; AlwaysEscapes effects were dropped by the
  // analyzer). Ordinary receivers are OrigAlloc; synthetic receivers are the
  // prepared SyntheticPhi.
  MaterializedReceiverOf[&E] = MatVal;

  Instruction *InsertBefore = dyn_cast_or_null<Instruction>(E.InsertBefore);
  assert(InsertBefore &&
         "Materialize InsertBefore was null at apply time — a sibling erase "
         "should have re-aimed it via relocateDependentMaterializes");
  BasicBlock *Origin = InsertBefore->getParent();

  // Replay field stores and re-emit locks immediately before the escape point.
  IRBuilder<> SB(Origin, InsertBefore->getIterator());
  if (InsertBefore->getDebugLoc())
    SB.SetCurrentDebugLocation(InsertBefore->getDebugLoc());
  Type *I8 = Type::getInt8Ty(Ctx);

  // Whether this apply actually mutated the IR (emitted at least one replay
  // store or re-emitted at least one lock). MaterializeEffect::apply gates
  // Ctx.Changed on this so an all-idle round (PartiallyEscapes VO with no
  // field stores and no surviving locks) does not needlessly keep the
  // iterative driver from converging. MaterializedReceiverOf population above
  // is not an IR mutation, and spliceUnparentedAt runs only inside the store
  // loop (gated by a store), so store/lock creation is the complete set of
  // mutations.
  bool Emitted = false;

  // Replay this object's tracked field stores onto its real receiver,
  // immediately before the escape point, so the object's fields hold their
  // current values when it escapes. The receiver and every field value
  // dominate this point
  // (analyzer per-field dominance invariant). A nested/peer virtual's field
  // value is its own OrigAlloc (the analyzer rewrites
  // VirtualRef→MaterializedRef during prerequisite materialization), which also
  // dominates here.
  for (const auto &FE : E.FieldEntries) {
    assert(jeandle::pea::isLegalMaterializationAtomicType(
               FE.Value.getDeclaredType(), DL) &&
           "materialize replay field must be a legal atomic store type");
    Value *V = nullptr;
    if (FE.Value.isScalar()) {
      V = FE.Value.getScalar();
    } else if (FE.Value.isMaterializedRef()) {
      V = FE.Value.getMaterialized();
    } else {
      // The analyzer rewrites every VirtualRef into MaterializedRef during
      // recursive prerequisite materialization; unknown entries are filtered at
      // snapshot time. Hitting another tag here is a contract violation.
      assert(false && "VirtualRef field entries must have been rewritten to "
                      "MaterializedRef during analysis");
      continue;
    }
    if (!V)
      continue;
    // An analyzer-built unparented value (e.g. a pea.coerce bitcast whose
    // owning ReplaceLoad was dropped) must be spliced before use; everything
    // else must already be in IR. Analysis-side scalar-alias normalization +
    // the commit availability sweep make this a defense-in-depth check.
    spliceUnparentedAt(InsertBefore, V);
    assert((isa<Constant>(V) || isa<Argument>(V) ||
            cast<Instruction>(V)->getParent() != nullptr) &&
           "materialize replay value must be a constant, argument, or "
           "in-IR instruction");
    Value *Slot =
        SB.CreateInBoundsGEP(I8, MatVal, SB.getInt64(FE.Offset), "pea.matslot");
    // Natural alignment = the field type's store size rounded up to a power of
    // two (atomic-unordered stores MUST be naturally aligned; ABI align may be
    // smaller than store size, e.g. i64 under the default datalayout). Derived
    // from the DataLayout so it stays correct under a future compressed-oop /
    // 32-bit heap model, and matches the frontend's natural-aligned emission.
    uint64_t StoreSz = DL.getTypeStoreSize(V->getType()).getFixedValue();
    Align NaturalAlign(llvm::PowerOf2Ceil(StoreSz ? StoreSz : 1));
    StoreInst *S = SB.CreateAlignedStore(V, Slot, NaturalAlign);
    S->setAtomic(AtomicOrdering::Unordered); // Java heap stores are unordered
    Emitted = true;
  }

  // Re-emit surviving monitorenters from the final result-owned physical plan.
  // Every lock-carrying site has one depth-sorted batch. Its tail effect emits
  // after every sibling receiver has been recorded; lockless sites need none.
  auto EmitLock = [&](Value *Recv, Function *Callee,
                      ArrayRef<WeakTrackingVH> NonReceiverArgs) -> bool {
    if (!Callee)
      return false;
    SmallVector<Value *, 4> Args;
    Args.push_back(Recv);
    for (Value *A : NonReceiverArgs)
      Args.push_back(A);
    CallInst *Enter = SB.CreateCall(Callee, Args);
    Enter->setCallingConv(CallingConv::Hotspot_JIT);
    // The re-emitted monitorenter is a REAL held lock on the replay receiver
    // (never a deopt safepoint), so it MUST carry no "deopt" operand bundle —
    // a bundle here would describe a MATERIALIZED VO's lock as a safepoint
    // state, double-counting it against the deopt-bundle monitor section.
    assert(!Enter->hasOperandBundles() &&
           "re-emitted monitorenter must be bare");
    return true;
  };
  // Lock lookup uses the ORIGINAL escape-point InsertBefore captured before
  // any eager-update re-aim, NOT the possibly re-aimed E.InsertBefore (an
  // eager-reaimed materialize would otherwise miss the physical batch). See the
  // canonical comment on LockReplayBatches in PartialEscape.h.
  Instruction *LockKey = OrigInsertBefore.lookup(&E);
  if (!LockKey)
    LockKey = InsertBefore;
  const jeandle::LockReplayBatch *ReplayBatch =
      Result.getLockReplayBatch(LockKey);
  assert((ReplayBatch || E.Locks.empty()) &&
         "every lock-carrying materialize must belong to a replay batch");
  if (ReplayBatch && E.SeqNo == ReplayBatch->EmitterSeqNo) {
    // Depth-ordering check: the batch must emit locks with strictly
    // increasing BytecodeDepth, the order in which the corresponding
    // monitorenters were taken in the source.
    bool First = true;
    uint32_t LastDepth = 0;
    for (const jeandle::MergedLock &ML : ReplayBatch->Locks) {
      assert((First || LastDepth < ML.BytecodeDepth) &&
             "emitted lock sequence must be strictly increasing in "
             "BytecodeDepth");
      First = false;
      LastDepth = ML.BytecodeDepth;
      auto NIt = MaterializedReceiverOf.find(ML.SourceEffect);
      assert(NIt != MaterializedReceiverOf.end() &&
             "every sibling's replay receiver must be recorded before the "
             "tail emits locks");
      Emitted |= EmitLock(NIt->second, ML.Callee, ML.NonReceiverArgs);
    }
  }

  return Emitted;
}

// Bundles the Function, the analysis result, and the shared per-apply state so
// each Effect subclass's apply() is self-contained.
//
// The struct carries the shared state used while effects apply; each member is
// documented at its definition.
struct jeandle::TransformContext {
  Function &F;
  jeandle::PEAResult &Result;
  bool &Changed;

  // effect -> real replay receiver (OrigAlloc or SyntheticPhi). Filled as each
  // Materialize applies; consumed by the tail effect at a multi-object escape
  // point to resolve each MergedLock's receiver.
  DenseMap<const jeandle::MaterializeEffect *, Value *> &MaterializedReceiverOf;

  // Reverse index: live InsertBefore -> Materialize effects keyed on it. A
  // sibling erase (ReplaceLoad/ReplaceCall/EliminateStore) consults this to
  // re-aim each dependent to the in-block successor before the erase nulls the
  // effect's WeakTrackingVH (see relocateDependentMaterializes).
  DenseMap<Instruction *, SmallVector<jeandle::MaterializeEffect *, 4>>
      &InsertBeforeDependents;

  // effect -> its ORIGINAL escape-point InsertBefore (captured before the
  // ordinary phase, before any eager-update re-aim). The lock re-emit looks up
  // LockReplayBatchForSite with this — the key computeEscapePointLocks used —
  // NOT the re-aimed E.InsertBefore, which could miss the key at a
  // multi-object escape point.
  DenseMap<const jeandle::MaterializeEffect *, Instruction *> &OrigInsertBefore;

  // A stable replay from a preceding outer round is retained in place when it
  // exactly matches this round's materialization plan. The corresponding
  // eliminate effects and materializations become real no-ops, allowing the
  // iterative driver to observe convergence without hiding an IR mutation.
  DenseSet<Instruction *> &PreservedReplayInstructions;
  DenseSet<const jeandle::MaterializeEffect *> &ReusedMaterializations;

  // Whole-pool effects whose safepoints are guaranteed to be deleted by an
  // ordinary or cfg-kill effect. They were validated as a unit by preflight
  // and intentionally do not rebuild a soon-to-die call.
  const DenseSet<const jeandle::RewriteDeoptPoolEffect *>
      &SkippedDeoptPoolEffects;
};

// Replace the load with its analyzer-computed replacement and erase it. An
// unparented analyzer-built replacement is spliced into the IR first.
//
// The erased load's metadata (!nonnull, !dereferenceable, !align, ...) is NOT
// transferred onto the replacement: those facts only held at the erased
// load's program point, while the replacement may also execute on paths that
// never reach it. Copying them would promote path-local facts to global ones
// (poison/UB on the bypassing paths). Graal keeps such a refinement sound by
// wrapping the replacement in a fresh PiNode anchored at the replaced node's
// position (GraphEffectList.replaceAtUsages); LLVM has no per-position value
// refinement here, so the refinement is dropped.
void jeandle::ReplaceLoadEffect::apply(jeandle::TransformContext &Ctx) {
  if (!Target || !Replacement)
    return;
  // Target is a WeakTrackingVH (see PartialEscape.h); it was non-null above,
  // so the instruction is still alive.
  Instruction *Target = cast<Instruction>((Value *)this->Target);
  Value *Repl = Replacement;
  // The analyzer may have synthesized an unparented coercion instruction as the
  // replacement (a same-bit-width `bitcast` reinterpretation). Splice it, and
  // any still-unparented operand, in postorder so each operand is parented
  // before its user; all land immediately before Target. A PHINode replacement
  // is owned by a CreatePHI effect that runs LATER in SeqNo order, so it is
  // treated as a leaf here (splicing it mid-block is illegal).
  spliceUnparentedAt(Target, Repl);
  if (!Target->use_empty())
    Target->replaceAllUsesWith(Repl);
  // Eager-update: re-aim any Materialize keyed on `Target` to its next
  // instruction before the erase nulls the WeakTrackingVH. Loads are never
  // block terminators, so getNextNode() is the in-block successor.
  relocateDependentMaterializes(Ctx.InsertBeforeDependents, Target,
                                Target->getNextNode());
  Target->eraseFromParent();
  Ctx.Changed = true;
}

void jeandle::ReplaceCallEffect::apply(jeandle::TransformContext &Ctx) {
  // JavaOp folded against a virtual receiver: non-void results are replaced
  // with a constant and the call erased; void JavaOps use a null Replacement to
  // request deletion only. Folded results that feed `br i1` leave constant
  // terminators cleaned up by ConstantFoldTerminator in run().
  if (!Target)
    return;
  // Target is a WeakTrackingVH (see PartialEscape.h); it was non-null above.
  Instruction *Target = cast<Instruction>((Value *)this->Target);
  if (Ctx.PreservedReplayInstructions.count(Target))
    return;
  // foldGetClass records the constant Class mirror by oop id rather than as an
  // LLVM value: building the GC-safe oop-handle load here (instead of during
  // analysis) keeps the analyzer side-effect-free. RS4GC, which runs downstream
  // of PEA, treats the loaded addrspace(1) value as a managed pointer and
  // inserts relocates. The load is inserted before Target so it dominates every
  // use after the RAUW below.
  Value *Repl = Replacement;
  if (OopHandleId >= 0) {
    IRBuilder<> Builder(Target);
    Repl = createConstOopLoad(*Ctx.F.getParent(), Builder, OopHandleId);
  }
  if (Repl) {
    Target->replaceAllUsesWith(Repl);
  } else if (!Target->use_empty()) {
    return;
  }
  // For InvokeInst we cannot simply erase — the unwind edge must be dropped
  // first. JavaOp folds emit `call` (not invoke) calls in practice; defensively
  // handle invokes.
  if (auto *II = dyn_cast<InvokeInst>(Target)) {
    BasicBlock *Normal = II->getNormalDest();
    BasicBlock *Unwind = II->getUnwindDest();
    BasicBlock *Parent = II->getParent();
    assert(Normal != Unwind && "PEA drops a folded JavaOp invoke's unwind "
                               "edge; normal and unwind dests must differ");
    Unwind->removePredecessor(Parent, /*KeepOneInputPHIs=*/true);
    BranchInst::Create(Normal, Parent);
    // Eager-update: re-aim any Materialize keyed on `II` to the freshly-created
    // `br` (II's normal successor in the SAME block) before erasing II. This
    // MUST use the `br` (II->getNextNode() after the Create), NOT
    // Normal->getFirstNonPHIOrDbg — the latter lives in the (multi-pred)
    // normal-dest block and would split the merge, replaying fields on every
    // predecessor's path (unsound).
    relocateDependentMaterializes(Ctx.InsertBeforeDependents, II,
                                  II->getNextNode());
    II->eraseFromParent();
  } else {
    // Eager-update: re-aim any Materialize keyed on `Target` to its next
    // instruction before the erase nulls the WeakTrackingVH.
    relocateDependentMaterializes(Ctx.InsertBeforeDependents, Target,
                                  Target->getNextNode());
    Target->eraseFromParent();
  }
  Ctx.Changed = true;
}

void jeandle::EliminateStoreEffect::apply(jeandle::TransformContext &Ctx) {
  if (!Target)
    return;
  if (Ctx.PreservedReplayInstructions.count(Target))
    return;
  // Eager-update (defensive): EliminateStore and Materialize-
  // at-store are mutually exclusive by the processStore dispatch, so this never
  // fires, but a store CAN be a Materialize IP (value-side fall-through),
  // so the hook is future-proof if that exclusion ever changes.
  relocateDependentMaterializes(Ctx.InsertBeforeDependents, Target,
                                Target->getNextNode());
  Target->eraseFromParent();
  Ctx.Changed = true;
}

void jeandle::EliminateAllocationEffect::apply(jeandle::TransformContext &Ctx) {
  // A PartiallyEscapes VO keeps its OrigAlloc (it is the single sound SSA value
  // for surviving uses and carries the allocation-site deopt bundle). Only
  // NeverEscapes OrigAllocs are erased. The analyzer still emits
  // EliminateAllocation for PartiallyEscapes VOs; those become redundant and
  // are silently skipped here. A genuine misclassification (e.g. an
  // AlwaysEscapes VO, or a non-allocation Target) still fails loudly inside
  // eraseAllocation's existing isJeandleAllocation asserts — the skip here only
  // suppresses the case the model requires (PartiallyEscapes OrigAlloc kept
  // alive). The check is classification-based (not OrigAlloc-pointer-based):
  // the deopt-pool phase may have cloned this allocation's invoke, so the live
  // instruction is the clone — the classification is clone-proof.
  assert(hasMutationOwner() &&
         "allocation elimination must have a mutation owner");
  auto ClassIt = Ctx.Result.EscapeClassification.find(getMutationOwner());
  if (ClassIt != Ctx.Result.EscapeClassification.end() &&
      ClassIt->second == jeandle::PEAResult::EscapeKind::PartiallyEscapes)
    return;
  if (!Target)
    return; // allocation was erased without replacement by a sibling effect.
  // Target is a WeakTrackingVH (see PartialEscape.h); it was non-null above.
  Instruction *Target = cast<Instruction>((Value *)this->Target);
  if (eraseAllocation(Target))
    Ctx.Changed = true;
}

void jeandle::MaterializeEffect::apply(jeandle::TransformContext &Ctx) {
  // Replay field stores and re-emit locks onto the real receiver (see
  // applyMaterialize and the file header). Changed is gated on actual emission
  // so an all-idle round does not block outer-fixpoint convergence (see
  // Emitted in applyMaterialize).
  if (Ctx.ReusedMaterializations.count(this)) {
    Ctx.MaterializedReceiverOf[this] = Target;
    return;
  }
  if (applyMaterialize(Ctx.F, Ctx.Result, *this, Ctx.MaterializedReceiverOf,
                       Ctx.OrigInsertBefore))
    Ctx.Changed = true;
}

void jeandle::CreatePHIEffect::apply(jeandle::TransformContext &Ctx) {
  // Field-value PHI: merges a per-offset field VALUE (scalar or
  // materialized-ref pointer) across preds / around a loop. Emitted by
  // mergeFieldStates and synthesizeCaseC. This is NOT a materialized-object
  // PHI — it tracks a real field value that must be merged. The analyzer's
  // recorded (PHIIncomingValues[I], PHIIncomingBlocks[I]) are valid as-is:
  // each incoming is a dominating field value, and a materialized-ref
  // incoming is the peer VO's OrigAlloc, which is kept alive.
  PHINode *Phi = PhiInst;
  assert(Phi && "CreatePHI effect requires a PhiInst");
  if (Phi->getParent()) {
    assert(Phi->getParent() == Block &&
           "CFG normalization must preserve the deferred PHI home block");
    return;
  }
  Phi->insertBefore(Block->getFirstNonPHIIt());
  assert(PHIIncomingValues.size() == PHIIncomingBlocks.size());
  for (unsigned I = 0; I < PHIIncomingValues.size(); ++I)
    Phi->addIncoming(PHIIncomingValues[I], PHIIncomingBlocks[I]);
  Ctx.Changed = true;
}

void jeandle::RewriteDeoptPoolEffect::apply(jeandle::TransformContext &Ctx) {
  if (Ctx.SkippedDeoptPoolEffects.count(this))
    return;

  // SafepointVH may follow an ordinary replacement. The raw key is deliberately
  // not followed: only the original call carries the source bundle validated
  // by this effect's immutable plan.
  Value *Tracked = SafepointVH;
  if (Tracked != SafepointKey)
    return;
  CallBase *CB = SafepointKey;
  assert(CB->getParent() && CB->getFunction() == &Ctx.F &&
         "preflighted deopt-pool safepoint must remain in its function");
  if (!getPlan().needsRewrite())
    return;

  pea::SerializeFinalDeoptPoolBundleResult Serialized =
      pea::serializeFinalDeoptPoolBundlePlan(getPlan(), *CB);
  if (!Serialized.Inputs)
    llvm_unreachable(
        "preflighted deopt-pool plan became stale before application");

  for (Value *V : *Serialized.Inputs) {
    spliceUnparentedAt(CB, V);
    assert((!isa<Instruction>(V) || cast<Instruction>(V)->getParent()) &&
           "deopt-pool token must be available before the safepoint");
  }

  CallBase *NewCB = CallBase::Create(
      CB, OperandBundleDef("deopt", *Serialized.Inputs), CB->getIterator());
  NewCB->takeName(CB);
  CB->replaceAllUsesWith(NewCB);
  CB->eraseFromParent();
  Ctx.Changed = true;
}

// Apply one explicit effect phase in SeqNo order (see Effect::SeqNo).
void jeandle::EffectList::apply(jeandle::TransformContext &Ctx,
                                jeandle::Effect::Phase Phase) {
  SmallVector<jeandle::Effect *, 16> Order;
  Order.reserve(Effects.size());
  for (auto &E : Effects)
    Order.push_back(E.get());
  llvm::sort(Order, [](const jeandle::Effect *A, const jeandle::Effect *B) {
    return A->SeqNo < B->SeqNo;
  });
  for (jeandle::Effect *E : Order)
    if (E->getPhase() == Phase)
      E->apply(Ctx);
}

namespace {

// Outcome of validating the whole-pool rewrites before any IR mutation (see
// preflightDeoptPoolEffects).
struct DeoptPoolPreflight {
  // Safepoints guaranteed to be erased by a matching ReplaceCall or
  // EliminateAllocation effect.
  DenseSet<CallBase *> GuaranteedDeletedSafepoints;
  // Whole-pool rewrites whose safepoint is in GuaranteedDeletedSafepoints;
  // applied as no-ops because rebuilding a soon-to-die call is wasted work.
  DenseSet<const jeandle::RewriteDeoptPoolEffect *> SkippedEffects;
};

// A matching ReplaceCall is guaranteed to erase Site unless replay-suffix
// matching retains it. Calls retained by that mechanism are monitorenters;
// an oop-handle replacement or an immutable SSA replacement is
// unconditionally available when the effect applies.
static bool
guaranteesSafepointDeletion(const jeandle::ReplaceCallEffect &Effect,
                            CallBase *Site) {
  if (Effect.getTarget() != Site || jeandle::pea::isJeandleMonitorEnter(Site))
    return false;
  Value *Replacement = Effect.Replacement;
  return (!Replacement && Site->use_empty()) || Effect.OopHandleId >= 0 ||
         isa_and_nonnull<Constant>(Replacement) ||
         isa_and_nonnull<Argument>(Replacement);
}

// A matching EliminateAllocation is guaranteed to erase Site when the owning
// VO is classified NeverEscapes (a PartiallyEscapes allocation is kept
// alive).
static bool
guaranteesSafepointDeletion(const jeandle::EliminateAllocationEffect &Effect,
                            const jeandle::PEAResult &Result, CallBase *Site) {
  if (Effect.getTarget() != Site || !Effect.hasMutationOwner())
    return false;
  auto It = Result.EscapeClassification.find(Effect.getMutationOwner());
  return It != Result.EscapeClassification.end() &&
         It->second == jeandle::PEAResult::EscapeKind::NeverEscapes;
}

// Validate every whole-pool transaction before splitReplayEdges or any other
// IR mutation. Serialization checks both the exact source fingerprint and all
// tracked output values/types. A site that is provably deleted does not need a
// rebuilt bundle, but still participates in the one-effect-per-safepoint
// invariant.
static bool preflightDeoptPoolEffects(const Function &F,
                                      const jeandle::PEAResult &Result,
                                      DeoptPoolPreflight &Preflight) {
  for (const auto &KV : Result.BlockEffects)
    for (const jeandle::Effect &Effect : KV.second) {
      if (const auto *Replace = dyn_cast<jeandle::ReplaceCallEffect>(&Effect)) {
        auto *Site = dyn_cast_or_null<CallBase>(Replace->getTarget());
        if (Site && guaranteesSafepointDeletion(*Replace, Site))
          Preflight.GuaranteedDeletedSafepoints.insert(Site);
        continue;
      }
      if (const auto *Eliminate =
              dyn_cast<jeandle::EliminateAllocationEffect>(&Effect)) {
        auto *Site = dyn_cast_or_null<CallBase>(Eliminate->getTarget());
        if (Site && guaranteesSafepointDeletion(*Eliminate, Result, Site))
          Preflight.GuaranteedDeletedSafepoints.insert(Site);
      }
    }

  DenseSet<CallBase *> SeenSafepoints;
  for (const auto &KV : Result.BlockEffects)
    for (const jeandle::Effect &Effect : KV.second) {
      const auto *Pool = dyn_cast<jeandle::RewriteDeoptPoolEffect>(&Effect);
      if (!Pool)
        continue;
      CallBase *Site = Pool->getSafepointKey();
      if (!Site || !Pool->hasPlan() || Effect.hasMutationOwner() ||
          !SeenSafepoints.insert(Site).second)
        return false;
      if (Pool->getTarget() != Site || !Site->getParent() ||
          Site->getFunction() != &F)
        return false;
      if (Preflight.GuaranteedDeletedSafepoints.count(Site)) {
        Preflight.SkippedEffects.insert(Pool);
        continue;
      }
      jeandle::pea::SerializeFinalDeoptPoolBundleResult Serialized =
          jeandle::pea::serializeFinalDeoptPoolBundlePlan(Pool->getPlan(),
                                                          *Site);
      if (!Serialized.Inputs)
        return false;
    }
  return true;
}

// The index of use U within Site's "deopt" operand bundle inputs, or
// std::nullopt when Site has no "deopt" bundle or U is not one of its inputs.
static std::optional<unsigned> getDeoptSemanticCell(const CallBase &Site,
                                                    const Use &U) {
  std::optional<OperandBundleUse> Deopt =
      Site.getOperandBundle(LLVMContext::OB_deopt);
  if (!Deopt)
    return std::nullopt;
  for (unsigned I = 0; I < Deopt->Inputs.size(); ++I)
    if (&Deopt->Inputs[I] == &U)
      return I;
  return std::nullopt;
}

} // namespace

// Transform pass entry point. Validates the analysis result (replay-store
// legality, unique SeqNos, whole-pool preflight) before any IR mutation,
// normalizes per-edge materialization sites, then applies effects in RPO per
// block in the three ordered phases (see the file header) and finishes with
// the canonical cleanups. Returns all-preserved when neither the effects nor
// the cleanups changed the IR.
PreservedAnalyses PartialEscapeTransform::run(Function &F,
                                              FunctionAnalysisManager &FAM) {
  // Gate on jeandle.java_method_compilation.
  Module *M = F.getParent();
  if (!M || !M->getNamedMetadata(jeandle::Metadata::JavaMethodCompilation))
    return PreservedAnalyses::all();

  auto &Result = FAM.getResult<PartialEscapeAnalysis>(F);
  if (!Result.hasOptimizationOpportunity())
    return PreservedAnalyses::all();
  // A malformed cached/custom analysis result must not mutate CFG or IR
  // before discovering that one replay store would be verifier-illegal.
  if (!Result.hasLegalMaterializationAtomicTypes(M->getDataLayout()))
    return PreservedAnalyses::all();
  assert(Result.hasUniqueEffectSequenceNumbers() &&
         "PEA effect sequence numbers must be globally unique");
  for (const auto &KV : Result.BlockEffects)
    for (const jeandle::Effect &Effect : KV.second)
      assert(Effect.hasValidMutationOwner() &&
             "only an atomic deopt-pool effect may be ownerless");

  DeoptPoolPreflight PoolPreflight;
  if (!preflightDeoptPoolEffects(F, Result, PoolPreflight))
    return PreservedAnalyses::all();

#ifndef NDEBUG
  // Debug-only audit of the NeverEscapes contract: the transform repeats the
  // analyzer's final eligibility walk (hasUnremovedSemanticUses) against the
  // committed effect plan. Every semantic use of a NeverEscapes allocation
  // must be provably removed by this pass — the user sits in a final dead
  // block, the user is erased by an ordinary effect, the user is a
  // PEA-handled non-escaping intrinsic, or the use is a "deopt" bundle input
  // of a safepoint that is itself guaranteed deleted or whose semantic cell
  // is rewritten away by that safepoint's whole-pool plan (directly, via a
  // current identity representing the source object, or via an occurrence
  // pruned from the plan).
  DenseSet<Instruction *> RemovedTargets;
  // Targets erased by ordinary effects.
  for (const auto &KV : Result.BlockEffects)
    for (const jeandle::Effect &E : KV.second)
      if (isa<jeandle::ReplaceLoadEffect>(E) ||
          isa<jeandle::ReplaceCallEffect>(E) ||
          isa<jeandle::EliminateStoreEffect>(E))
        if (Instruction *Target = E.getTarget())
          RemovedTargets.insert(Target);
  for (const auto &KV : Result.EscapeClassification) {
    if (KV.second != jeandle::PEAResult::EscapeKind::NeverEscapes)
      continue;
    const jeandle::VirtualObject &VObj = *Result.VirtualObjects[KV.first];
    if (VObj.IsSynthetic)
      continue;
    Value *Allocation = VObj.AllocationCall;
    assert(Allocation && "NeverEscapes object must retain its allocation");
    bool HasSurvivingUse =
        jeandle::pea::hasUnremovedSemanticUses(Allocation, [&](const Use &U) {
          auto *UserI = dyn_cast<Instruction>(U.getUser());
          if (UserI && Result.FinalDeadBlocks.count(UserI->getParent()))
            return true;
          if (UserI && RemovedTargets.count(UserI))
            return true;
          auto *CB = dyn_cast_or_null<CallBase>(UserI);
          if (!CB)
            return false;
          if (!CB->isBundleOperand(U.getOperandNo()))
            return jeandle::pea::isPEAHandledNonEscapingIntrinsic(
                dyn_cast<IntrinsicInst>(CB));
          OperandBundleUse Bundle =
              CB->getOperandBundleForOperand(U.getOperandNo());
          if (!Bundle.isDeoptOperandBundle())
            return jeandle::pea::isPEAHandledNonEscapingIntrinsic(
                dyn_cast<IntrinsicInst>(CB));
          if (PoolPreflight.GuaranteedDeletedSafepoints.count(CB))
            return true;
          std::optional<unsigned> SemanticCell = getDeoptSemanticCell(*CB, U);
          if (!SemanticCell)
            return false;
          for (const auto &EffectsKV : Result.BlockEffects)
            for (const jeandle::Effect &E : EffectsKV.second) {
              const auto *Pool = dyn_cast<jeandle::RewriteDeoptPoolEffect>(&E);
              if (!Pool || Pool->getSafepointKey() != CB)
                continue;
              if (Pool->coversExactOccurrence(*SemanticCell, KV.first))
                return true;
              for (jeandle::pea::CurrentDeoptNodeID CurrentID :
                   Pool->getPlan().graph().currentMembers())
                if (Pool->coversExactOccurrence(*SemanticCell, CurrentID) &&
                    Result.currentIdentityRepresentsSource(CurrentID, KV.first))
                  return true;
              for (const auto &Occurrence :
                   Pool->getPlan().currentOccurrences())
                if (Occurrence.Disposition ==
                        jeandle::pea::FinalDeoptPoolOccurrenceDisposition::
                            RemovedByPruning &&
                    Occurrence.SemanticCell &&
                    *Occurrence.SemanticCell == *SemanticCell &&
                    Result.currentIdentityRepresentsSource(Occurrence.CurrentID,
                                                           KV.first))
                  return true;
            }
          return false;
        });
    assert(!HasSurvivingUse &&
           "NeverEscapes allocation has a surviving semantic use");
  }
#endif

  bool Changed = false;

  // See TransformContext::MaterializedReceiverOf.
  DenseMap<const jeandle::MaterializeEffect *, Value *> MaterializedReceiverOf;

  // Normalize incoming-edge materializations before RPO and before replay
  // batches capture their physical insertion sites.  SplitBlockPredecessors
  // updates target PHIs and clones landingpads when the target is an EH pad.
  Changed |= splitReplayEdges(Result);

  ReversePostOrderTraversal<Function *> RPOT(&F);

  // Build the per-escape-point merged lock lists (one global depth-sort per
  // materialize point) before the ordinary phase applies effects. Re-entrant
  // interleaved lock stacks across objects at one escape point MUST be
  // re-emitted as ONE globally depth-sorted list (per-object emission would
  // mis-order them on the runtime lock stack).
  Result.computeEscapePointLocks();

  // See TransformContext::InsertBeforeDependents.
  DenseMap<Instruction *, SmallVector<jeandle::MaterializeEffect *, 4>>
      InsertBeforeDependents;
  // See TransformContext::OrigInsertBefore.
  DenseMap<const jeandle::MaterializeEffect *, Instruction *> OrigInsertBefore;
  DenseMap<Instruction *, SmallVector<jeandle::MaterializeEffect *, 4>>
      MaterializationsAt;
  for (auto &Kv : Result.BlockEffects)
    for (jeandle::Effect &E : Kv.second) {
      auto *M = dyn_cast<jeandle::MaterializeEffect>(&E);
      if (!M)
        continue;
      if (Instruction *Key = dyn_cast_or_null<Instruction>(M->InsertBefore)) {
        InsertBeforeDependents[Key].push_back(M);
        OrigInsertBefore.try_emplace(M, Key);
        MaterializationsAt[Key].push_back(M);
      }
    }

  DenseSet<Instruction *> PreservedReplayInstructions;
  DenseSet<const jeandle::MaterializeEffect *> ReusedMaterializations;
  for (auto &KV : MaterializationsAt) {
    SmallVector<Instruction *, 16> MatchingInstructions;
    if (!matchExistingReplaySuffix(KV.first, KV.second, Result,
                                   MatchingInstructions))
      continue;
    PreservedReplayInstructions.insert(MatchingInstructions.begin(),
                                       MatchingInstructions.end());
    ReusedMaterializations.insert(KV.second.begin(), KV.second.end());
  }

  // -------------------------------------------------------------------------
  // Phase 1: ordinary effects establish the final SSA values and replay state.
  // -------------------------------------------------------------------------
  jeandle::TransformContext Ctx{F,
                                Result,
                                Changed,
                                MaterializedReceiverOf,
                                InsertBeforeDependents,
                                OrigInsertBefore,
                                PreservedReplayInstructions,
                                ReusedMaterializations,
                                PoolPreflight.SkippedEffects};

  for (BasicBlock *BB : RPOT) {
    auto It = Result.BlockEffects.find(BB);
    if (It == Result.BlockEffects.end())
      continue;
    It->second.apply(Ctx, jeandle::Effect::Phase::Ordinary);
  }

  // -------------------------------------------------------------------------
  // Phase 2: rewrite each surviving safepoint's complete deopt object pool
  // after ordinary replacements have settled and before allocation identities
  // can be deleted.
  // -------------------------------------------------------------------------
  for (BasicBlock *BB : RPOT) {
    auto It = Result.BlockEffects.find(BB);
    if (It == Result.BlockEffects.end())
      continue;
    It->second.apply(Ctx, jeandle::Effect::Phase::DeoptPool);
  }

  // -------------------------------------------------------------------------
  // Phase 3: allocation/CFG kills. NeverEscapes OrigAllocs are erased here;
  // PartiallyEscapes OrigAllocs remain alive.
  // -------------------------------------------------------------------------
  for (BasicBlock *BB : RPOT) {
    auto It = Result.BlockEffects.find(BB);
    if (It == Result.BlockEffects.end())
      continue;
    It->second.apply(Ctx, jeandle::Effect::Phase::CfgKill);
  }

  // Erase parented Case-B alias PHIs (Case B: a pointer PHI whose incomings
  // all resolve to the same still-virtual ObjectID, so the PHI merely aliases
  // that VO; see PartialEscapeAnalysis.cpp) that the analyzer flagged as
  // redundant for NeverEscapes VOs. The cfg-kill phase above already RAUW'd
  // every OrigAlloc incoming to poison via eraseAllocation, so the PHIs
  // survive as `phi [poison, poison]`. Replace each with poison and erase.
  // WeakTrackingVH auto-nulls if some other code path already deleted the PHI
  // (e.g. an outer iteration's dead-block sweep), so the null check below is
  // load-bearing.
  for (auto &VH : Result.CaseBAliasedPhisToErase) {
    Value *V = VH;
    if (!V)
      continue;
    auto *Phi = dyn_cast<PHINode>(V);
    if (!Phi || !Phi->getParent())
      continue;
    Phi->replaceAllUsesWith(PoisonValue::get(Phi->getType()));
    Phi->eraseFromParent();
    Changed = true;
  }

  if (!Changed && !Result.NeedsCFGCleanup)
    return PreservedAnalyses::all();

  // Folded JavaOps may have left behind `br i1 true|false, ...` terminators
  // (monitorenter elision RAUWs the result to `true`, after which a
  // conditional branch on the result becomes constant). Use
  // ConstantFoldTerminator to collapse those before the unreachable-block
  // sweep so the slow-path blocks of synchronized regions get cleaned up.
  for (BasicBlock &BB : llvm::make_early_inc_range(F)) {
    Changed |= ConstantFoldTerminator(&BB, /*DeleteDeadConditions=*/true,
                                      /*TLI=*/nullptr, /*DTU=*/nullptr);
  }

  // Fold trivial PHIs. No materialized-object PHI is created (OrigAlloc is the
  // single value), but field-value PHIs created by CreatePHIEffect can still
  // collapse to a single value when every incoming agrees (e.g. a loop
  // field-PHI whose only back-edge incoming is the same value as the preheader
  // incoming), and nested loops can leave dead PHI cycles.
  // PHINode::hasConstantValue collapses both phi(X,X) and phi(self, X) to X;
  // iterate to fixpoint so a fold that makes an enclosing phi trivial is
  // caught. The trivially-dead sweep below cannot break a PHI cycle (each phi
  // is "used" by the next), so this runs first. (Mirrors downstream
  // GVN/InstCombine; doing it here keeps PEA output clean.)
  bool FoldedPhi = true;
  while (FoldedPhi) {
    FoldedPhi = false;
    for (BasicBlock &BB : F) {
      for (Instruction &I : llvm::make_early_inc_range(BB)) {
        auto *PN = dyn_cast<PHINode>(&I);
        if (!PN || PN->getNumIncomingValues() == 0)
          continue;
        if (Value *V = PN->hasConstantValue()) {
          PN->replaceAllUsesWith(V);
          PN->eraseFromParent();
          FoldedPhi = true;
          Changed = true;
        }
      }
    }
  }

  // Sweep trivially-dead instructions that became unused after our rewrites
  // (e.g., GEPs derived from eliminated allocations whose only users were the
  // loads/stores we replaced in the ordinary phase). Iterate to fixpoint so
  // cascading deaths are caught.
  bool LocalChanged = true;
  while (LocalChanged) {
    LocalChanged = false;
    for (BasicBlock &BB : llvm::make_early_inc_range(F)) {
      for (Instruction &I : llvm::make_early_inc_range(BB)) {
        if (isInstructionTriviallyDead(&I)) {
          I.eraseFromParent();
          LocalChanged = true;
          Changed = true;
        }
      }
    }
  }

  // Clean up unwind blocks that became unreachable after invoke→br rewrites
  // and slow-path blocks orphaned by ConstantFoldTerminator above.
  Changed |= EliminateUnreachableBlocks(F);

  // Drop references on still-unparented OwnedInsts before verifyFunction: the
  // PEAResult destructor (which runs in the analysis manager, after the
  // verifier) would clean them up, but without this sweep an unparented helper
  // holding a use of a now-parented helper trips the verifier's "use list of X
  // is in IR but X's user is not". dropAllReferences() severs the use list
  // without freeing the value; the dtor still owns the WeakTrackingVH and does
  // the eventual deleteValue.
  for (WeakTrackingVH &VH : Result.OwnedInsts) {
    if (Value *V = VH) {
      if (auto *I = dyn_cast<Instruction>(V)) {
        if (!I->getParent())
          I->dropAllReferences();
      }
    }
  }

  // In debug builds, verify the rewritten IR so any PEA malformation (broken
  // SSA from a stale RAUW, mis-ordered CreatePHI vs per-pred Materialize,
  // value-side virtual leak, critical-edge replacement, missing funclet
  // bundle, ...) is caught here with an actionable message rather than later
  // in RewriteStatepointsForGC or assembly emission.
#ifndef NDEBUG
  if (verifyFunction(F, &errs())) {
    errs() << "PEA: produced malformed IR for " << F.getName() << "\n";
    llvm_unreachable("PartialEscapeTransform produced malformed IR");
  }
#endif

  return Changed ? PreservedAnalyses::none() : PreservedAnalyses::all();
}
