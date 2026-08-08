//===- SafepointStripMining.cpp - Jeandle safepoint strip mining ---------===//
//
// Copyright (c) 2026, the Jeandle-LLVM Authors. All Rights Reserved.
//
// Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM
// Exceptions. See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#include "llvm/Transforms/Jeandle/SafepointStripMining.h"
#include "llvm/ADT/DenseMap.h"
#include "llvm/ADT/PostOrderIterator.h"
#include "llvm/ADT/STLExtras.h"
#include "llvm/ADT/SmallPtrSet.h"
#include "llvm/ADT/SmallVector.h"
#include "llvm/Analysis/CFG.h"
#include "llvm/Analysis/IVDescriptors.h"
#include "llvm/Analysis/LoopInfo.h"
#include "llvm/Analysis/MemorySSA.h"
#include "llvm/Analysis/ScalarEvolution.h"
#include "llvm/Analysis/ScalarEvolutionExpressions.h"
#include "llvm/Analysis/ValueTracking.h"
#include "llvm/IR/BasicBlock.h"
#include "llvm/IR/CFG.h"
#include "llvm/IR/Constants.h"
#include "llvm/IR/Dominators.h"
#include "llvm/IR/Function.h"
#include "llvm/IR/IRBuilder.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/Intrinsics.h"
#include "llvm/IR/Jeandle/Attributes.h"
#include "llvm/IR/Jeandle/JeandleUtils.h"
#include "llvm/IR/Jeandle/Metadata.h"
#include "llvm/IR/ValueMap.h"
#include "llvm/Support/Debug.h"
#include "llvm/Transforms/Jeandle/SafepointUtils.h"
#include "llvm/Transforms/Utils/BasicBlockUtils.h"
#include "llvm/Transforms/Utils/Cloning.h"
#include "llvm/Transforms/Utils/LoopUtils.h"

using namespace llvm;

#define DEBUG_TYPE "safepoint-strip-mining"

namespace {

using jeandle::canProveExclusiveNoWrap;
using jeandle::canProveInclusiveNoWrap;
using jeandle::getConstantAddStep;
using jeandle::isSafepointPoll;
using jeandle::StripMineStrideOverflowWidenBits;

constexpr StringRef InclusiveSlowPathMD = jeandle::Metadata::InclusiveSlowPath;

[[maybe_unused]] StringRef modeName(SafepointStripMiningMode Mode) {
  switch (Mode) {
  case SafepointStripMiningMode::StripMining:
    return "strip-mining";
  case SafepointStripMiningMode::InclusiveLoopVersioning:
    return "inclusive-loop-versioning";
  }
  llvm_unreachable("unknown SafepointStripMiningMode");
}

// ===--------------------------------------------------------------------===//
// Strip mining for unbounded / large counted loops.
//
// A loop whose trip count is not provably within the chunk budget can't have
// its back-edge poll deleted without leaving the loop naked. Following C2's
// OuterStripMinedLoopNode, wrap the loop in an outer loop that iterates the
// original IV space in batches of N: the inner loop runs poll-free (so it can
// vectorize / LICM / widen its IV) and a single poll on the outer back-edge
// keeps time-to-safepoint bounded to N inner iterations.
//
// The poll is relocated, never synthesized: the inner back-edge poll is
// cloned onto the outer latch with its deopt bundle carried over and the
// loop-carried operands remapped to the outer recurrences. A poll whose deopt
// state can't be remapped — it references a value that is neither the IV, a
// header recurrence, nor loop-invariant — makes the loop ineligible; we keep
// it as-is rather than emit a safepoint with wrong deopt state.
// ===--------------------------------------------------------------------===//

struct IVInfo {
  PHINode *Phi;
  Value *ComparedValue;
  APInt Step;
  const SCEVAddRecExpr *AR;
};

// The integer induction phi whose latch-carried next value ExitCmp compares
// directly against a loop-invariant limit, with a compile-time non-zero
// constant step. LoopRotate delivers this latch-exit (post-increment) shape;
// the cmp's limit rewrite stays a single operand swap, and the IV is tied to
// the exit test, so a loop with several affine recurrences strip-mines on the
// one the exit drives.
std::optional<IVInfo> findIntInduction(Loop *L, ICmpInst *ExitCmp,
                                       ScalarEvolution &SE) {
  PHINode *Phi = L->getInductionVariable(SE);
  if (!Phi)
    return std::nullopt;
  InductionDescriptor IndDesc;
  if (!L->getInductionDescriptor(SE, IndDesc))
    return std::nullopt;
  ConstantInt *Step = IndDesc.getConstIntStepValue();
  if (!Step || Step->isZero())
    return std::nullopt;

  Value *LatchValue = Phi->getIncomingValueForBlock(L->getLoopLatch());
  Value *Op0 = ExitCmp->getOperand(0);
  Value *Op1 = ExitCmp->getOperand(1);
  Value *Limit = nullptr;
  Value *ComparedValue = nullptr;
  if (Op0 == LatchValue) {
    Limit = Op1;
    ComparedValue = Op0;
  } else if (Op1 == LatchValue) {
    Limit = Op0;
    ComparedValue = Op1;
  } else {
    return std::nullopt;
  }
  if (!SE.isLoopInvariant(SE.getSCEV(Limit), L))
    return std::nullopt;
  const auto *AR = dyn_cast<SCEVAddRecExpr>(SE.getSCEV(Phi));
  if (!AR || AR->getLoop() != L || !AR->isAffine())
    return std::nullopt;
  return IVInfo{Phi, ComparedValue, Step->getValue(), AR};
}

// Relational predicates are handled directly. eq/ne loops are accepted here so
// checkStripMineShape can support the `i != limit` counted-loop subset when the
// continue predicate normalizes to NE and the step is exactly +/-1.
bool isAcceptablePredicate(ICmpInst::Predicate P) {
  return ICmpInst::isRelational(P) || P == ICmpInst::ICMP_EQ ||
         P == ICmpInst::ICMP_NE;
}

struct StripMineShape {
  BasicBlock *Preheader, *Header, *Latch, *ExitingBB, *ExitBB;
  BranchInst *ExitingBr;
  Value *ResumeIV;
  unsigned ExitSuccessorIdx;
  unsigned LimitOperandIdx;
  bool Increasing;
  bool Inclusive; // ContinuePredicate is *LE / *GE (runs one extra iteration)
  bool FirstIterationGuaranteed;
  ICmpInst::Predicate ContinuePredicate;
};

// Narrow preconditions kept simple so the CFG surgery is auditable:
// LoopSimplify form, a single primary counted exit whose conditional branch is
// ExitCmp (ordinary side exits are permitted alongside it), a relational
// predicate whose direction matches the step sign, and the IV phi compared
// directly against a loop-invariant limit.
std::optional<StripMineShape> checkStripMineShape(Loop *L, const IVInfo &IV,
                                                  ICmpInst *ExitCmp,
                                                  ScalarEvolution &SE) {
  // LoopSimplify form is defined as having a preheader, a single latch, and
  // dedicated exits, so getLoopPreheader()/getLoopLatch() are non-null here.
  if (!L->isLoopSimplifyForm())
    return std::nullopt;
  BasicBlock *Preheader = L->getLoopPreheader();
  BasicBlock *Header = L->getHeader();
  BasicBlock *Latch = L->getLoopLatch();

  // The surgery reroutes the preheader's branch into the new outer preheader.
  // LoopSimplify gives the preheader a single successor but not necessarily a
  // plain BranchInst terminator (a callbr could reach the header), so require
  // one here — before any mutation — rather than cast blindly mid-surgery.
  if (!isa<BranchInst>(Preheader->getTerminator()))
    return std::nullopt;

  // The surgery rewires the primary counted exit only. Any other exit edge
  // already leaves the current loop and, after wrapping, the strip-mined nest,
  // so it is not part of the long-running back-edge path that needs bounded
  // TTSP coverage; keep it and its exit state untouched. This mirrors C2
  // CountedLoop's "1 trip-counter exit path and maybe other exit paths"
  // contract.
  BasicBlock *ExitingBB = ExitCmp->getParent();
  SmallVector<BasicBlock *, 4> ExitingBBs;
  L->getExitingBlocks(ExitingBBs);
  if (!llvm::is_contained(ExitingBBs, ExitingBB))
    return std::nullopt;

  // LoopRotate delivers a latch-exit (post-increment) loop: the counted test
  // lives in the latch and compares the latch-carried next value against a
  // loop-invariant limit. A loop that did not rotate into this shape has no
  // latch compare (buildStripMinePlan's getLatchCmpInst returned null) and
  // never reaches here, so only the latch-carried next-value compare is
  // handled.
  Value *LatchIV = IV.Phi->getIncomingValueForBlock(Latch);
  if (ExitingBB != Latch)
    return std::nullopt;
  auto LatchStep = getConstantAddStep(LatchIV, IV.Phi);
  if (!LatchStep || *LatchStep != IV.Step)
    return std::nullopt;
  auto *LatchNextInst = dyn_cast<Instruction>(LatchIV);
  if (!LatchNextInst || !L->contains(LatchNextInst))
    return std::nullopt;

  auto *Br = dyn_cast<BranchInst>(ExitingBB->getTerminator());
  if (!Br || !Br->isConditional() || Br->getCondition() != ExitCmp)
    return std::nullopt;

  // The surgery rewrites ExitCmp's limit operand in place to the clamped
  // per-batch limit. If ExitCmp feeds anything other than this branch (a
  // select, another branch, a side-exit poll's deopt bundle), that user would
  // silently start reading the clamped limit instead of the real one. Only
  // rewrite a compare used solely by the exit branch. (EarlyCSE, now in the
  // strip-mining pipeline, can merge equal compares into a shared multi-use
  // value, so this is not hypothetical.)
  if (!ExitCmp->hasOneUse())
    return std::nullopt;

  unsigned ExitSuccIdx = 0;
  BasicBlock *ExitBB = nullptr;
  for (unsigned I = 0; I < Br->getNumSuccessors(); ++I) {
    if (!L->contains(Br->getSuccessor(I))) {
      if (ExitBB)
        return std::nullopt; // more than one exit edge from this branch
      ExitBB = Br->getSuccessor(I);
      ExitSuccIdx = I;
    }
  }
  if (!ExitBB)
    return std::nullopt;

  // Normalise branch polarity: reason in terms of the predicate that is true
  // when we should *continue* the inner batch, so exit-on-true and
  // exit-on-false shapes are handled on equal footing.
  bool ExitOnTrue = (ExitSuccIdx == 0);
  ICmpInst::Predicate ContinuePred =
      ExitOnTrue ? ICmpInst::getInversePredicate(ExitCmp->getPredicate())
                 : ExitCmp->getPredicate();

  unsigned LimitIdx;
  bool ComparedOnRHS = false;
  if (ExitCmp->getOperand(0) == IV.ComparedValue)
    LimitIdx = 1;
  else if (ExitCmp->getOperand(1) == IV.ComparedValue) {
    LimitIdx = 0;
    ComparedOnRHS = true;
  } else {
    return std::nullopt;
  }
  if (ComparedOnRHS)
    ContinuePred = ICmpInst::getSwappedPredicate(ContinuePred);

  bool CanonicalizedNE = ContinuePred == ICmpInst::ICMP_NE;
  if (CanonicalizedNE) {
    if (!IV.Step.abs().isOne())
      return std::nullopt;
    ContinuePred =
        IV.Step.isStrictlyPositive() ? ICmpInst::ICMP_SLT : ICmpInst::ICMP_SGT;
  }

  bool Increasing, Inclusive;
  switch (ContinuePred) {
  case ICmpInst::ICMP_SLT:
  case ICmpInst::ICMP_ULT:
    Increasing = true;
    Inclusive = false;
    break;
  case ICmpInst::ICMP_SLE:
  case ICmpInst::ICMP_ULE:
    Increasing = true;
    Inclusive = true;
    break;
  case ICmpInst::ICMP_SGT:
  case ICmpInst::ICMP_UGT:
    Increasing = false;
    Inclusive = false;
    break;
  case ICmpInst::ICMP_SGE:
  case ICmpInst::ICMP_UGE:
    Increasing = false;
    Inclusive = true;
    break;
  default:
    return std::nullopt;
  }
  if (Increasing != IV.Step.isStrictlyPositive())
    return std::nullopt; // step direction conflicts with predicate direction

  // The limit's loop-invariance is already established by findIntInduction
  // (SE.isLoopInvariant(SE.getSCEV(Limit), L)); no need to re-check here.

  const SCEV *Start = IV.AR->getStart();
  const SCEV *Limit = SE.getSCEV(ExitCmp->getOperand(LimitIdx));
  bool FirstIterationGuaranteed =
      SE.isLoopEntryGuardedByCond(L, ContinuePred, Start, Limit);
  // NE is equivalent to the normalized relational predicate only when the
  // entry order and unit step prove that the IV reaches the limit without
  // passing it. A post-tested skeleton preserves the mandatory first
  // iteration, but it cannot supply that reachability proof.
  if (CanonicalizedNE && !FirstIterationGuaranteed)
    return std::nullopt;

  return StripMineShape{Preheader,   Header,      Latch,
                        ExitingBB,   ExitBB,      Br,
                        LatchIV,     ExitSuccIdx, LimitIdx,
                        Increasing,  Inclusive,   FirstIterationGuaranteed,
                        ContinuePred};
}

// Back-edge polls owned by L (not a sub-loop) whose block dominates the latch:
// these fire on every iteration that reaches the back-edge, so they are the
// relocation candidates for strip mining. (The back-edge poll may sit in a
// header/body block that dominates the latch, not only in the latch itself.)
// Dominance proves coverage only; relocation's separate memory and deopt-state
// gates below do the real work; the loop-tree poll-deletion pass owns polls
// that are not on the back-edge path (early-return, conditional).
SmallVector<CallInst *, 4> collectBackEdgePolls(Loop *L, LoopInfo &LI,
                                                DominatorTree &DT) {
  BasicBlock *Latch = L->getLoopLatch();
  SmallVector<CallInst *, 4> Out;
  for (BasicBlock *BB : L->blocks()) {
    if (LI.getLoopFor(BB) != L)
      continue;
    if (!DT.dominates(BB, Latch))
      continue;
    for (Instruction &I : *BB)
      if (isSafepointPoll(I))
        Out.push_back(cast<CallInst>(&I));
  }
  return Out;
}

CallInst *findRelocationCandidate(Loop *L, LoopInfo &LI, DominatorTree &DT) {
  BasicBlock *Latch = L->getLoopLatch();
  for (BasicBlock *BB = Latch; BB && L->contains(BB);) {
    if (LI.getLoopFor(BB) == L)
      for (Instruction &I : llvm::reverse(*BB))
        if (isSafepointPoll(I))
          return cast<CallInst>(&I);

    DomTreeNode *Node = DT.getNode(BB);
    DomTreeNode *IDom = Node ? Node->getIDom() : nullptr;
    BB = IDom ? IDom->getBlock() : nullptr;
  }
  return nullptr;
}

// The value a header phi carries from the latch edge — the loop-carried "next"
// value (e.g. i.next, s.next). The frontend's back-edge deopt bundle captures
// these, not the phis themselves (the state is "resume at the next iteration").
PHINode *getHeaderPhiForLatchValue(Value *V, BasicBlock *Header,
                                   BasicBlock *Latch) {
  for (PHINode &Phi : Header->phis())
    if (Phi.getIncomingValueForBlock(Latch) == V)
      return &Phi;
  return nullptr;
}

bool isHeaderPhiLatchValue(Value *V, BasicBlock *Header, BasicBlock *Latch) {
  return getHeaderPhiForLatchValue(V, Header, Latch) != nullptr;
}

// Frontends may keep an unchanged local (notably `this`) live across a loop as
// a syntactic self recurrence. It is semantically invariant, so its preheader
// value is the value observed at every batch boundary.
Value *getLoopInvariantSelfRecurrenceInitial(PHINode *Phi, Loop *L,
                                             BasicBlock *Header,
                                             BasicBlock *Latch) {
  if (Phi->getParent() != Header || Phi->getIncomingValueForBlock(Latch) != Phi)
    return nullptr;
  BasicBlock *Preheader = L->getLoopPreheader();
  Value *Initial =
      Preheader ? Phi->getIncomingValueForBlock(Preheader) : nullptr;
  return Initial && L->isLoopInvariant(Initial) ? Initial : nullptr;
}

struct DeoptBoundaryValue {
  Value *Original;
  // The value reached by walking Casts from Original. Null means Original is
  // defined outside the loop and can be reused directly.
  Value *OriginalRoot;
  // The value from which the outer-boundary expression is rebuilt. This is the
  // root itself for an invariant/latch-carried root, or the preheader value for
  // an invariant self recurrence.
  Value *BoundaryBase;
  Value *LatchValue;
  // Outermost-to-innermost casts from Original down to OriginalRoot. Applying
  // the plan walks this list in reverse and memoizes each rebuilt cast.
  SmallVector<CastInst *, 2> Casts;
};

// The relocated poll represents the next iteration at a batch boundary. A raw
// header phi is normally current-iteration state, even when it also happens to
// be the latch input of another copy/swap recurrence. The one safe exception is
// an invariant self recurrence. Other operands must either be loop-invariant,
// a latch-carried next value, or a pure cast chain rooted at such a next value.
// The returned plans are consumed verbatim during relocation, keeping the
// eligibility proof and materialization behavior in sync.
std::optional<SmallVector<DeoptBoundaryValue, 8>>
analyzeDeoptBoundaryValues(CallInst *P, Loop *L, BasicBlock *Header,
                           BasicBlock *Latch) {
  SmallVector<DeoptBoundaryValue, 8> Plans;
  auto OB = P->getOperandBundle(LLVMContext::OB_deopt);
  if (!OB)
    return Plans;
  for (const Use &U : OB->Inputs) {
    Value *V = U.get();
    if (L->isLoopInvariant(V)) {
      Plans.push_back({V, nullptr, nullptr, nullptr, {}});
      continue;
    }
    if (auto *Phi = dyn_cast<PHINode>(V); Phi && Phi->getParent() == Header) {
      if (Value *Initial =
              getLoopInvariantSelfRecurrenceInitial(Phi, L, Header, Latch)) {
        Plans.push_back({V, V, Initial, nullptr, {}});
        continue;
      }
      return std::nullopt;
    }

    SmallVector<CastInst *, 2> Casts;
    Value *Root = V;
    while (auto *Cast = dyn_cast<CastInst>(Root)) {
      Casts.push_back(Cast);
      Root = Cast->getOperand(0);
    }
    if (L->isLoopInvariant(Root)) {
      Plans.push_back({V, Root, Root, nullptr, std::move(Casts)});
      continue;
    }
    if (auto *Phi = dyn_cast<PHINode>(Root);
        Phi && Phi->getParent() == Header) {
      if (Value *Initial =
              getLoopInvariantSelfRecurrenceInitial(Phi, L, Header, Latch)) {
        Plans.push_back({V, Root, Initial, nullptr, std::move(Casts)});
        continue;
      }
      return std::nullopt;
    }
    if (!isHeaderPhiLatchValue(Root, Header, Latch))
      return std::nullopt;
    Plans.push_back({V, Root, Root, Root, std::move(Casts)});
  }
  return Plans;
}

bool memoryStateMatchesBackedge(CallInst *Poll, Loop *L, BasicBlock *Header,
                                BasicBlock *Latch, MemorySSA &MSSA) {
  MemoryAccess *PollAccess = MSSA.getMemoryAccess(Poll);
  if (!PollAccess)
    return false;

  assert(isa<MemoryDef>(PollAccess) && "safepoint poll must be a MemoryDef");

  MemoryPhi *HeaderMemory = MSSA.getMemoryAccess(Header);
  if (HeaderMemory) {
    if (HeaderMemory->getBasicBlockIndex(Latch) < 0)
      return false;
    return HeaderMemory->getIncomingValueForBlock(Latch) == PollAccess;
  }

  // With no loop-header MemoryPhi, only a MemoryUse can be loop-invariant.
  return false;
}

bool isUnmodeledRelocationHazard(const Instruction &I, MemorySSA &MSSA) {
  if (I.isDebugOrPseudoInst() || I.isLifetimeStartOrEnd())
    return false;
  return I.mayHaveSideEffects() && !MSSA.getMemoryAccess(&I);
}

// Walk backward from the latch and stop at the poll block. Since the poll block
// dominates the latch, this visits exactly the current-iteration paths that can
// still reach the backedge and ignores side-exit-only paths.
bool hasNoUnmodeledRelocationHazardAfterPoll(CallInst *Poll, Loop *L,
                                             BasicBlock *Latch,
                                             MemorySSA &MSSA) {
  BasicBlock *PollBB = Poll->getParent();
  SmallVector<BasicBlock *, 8> Worklist{Latch};
  SmallPtrSet<BasicBlock *, 16> Visited;
  bool ReachedPoll = false;

  while (!Worklist.empty()) {
    BasicBlock *BB = Worklist.pop_back_val();
    if (!Visited.insert(BB).second)
      continue;
    if (!L->contains(BB))
      return false;

    if (BB == PollBB) {
      ReachedPoll = true;
      for (auto It = std::next(Poll->getIterator()), End = BB->end(); It != End;
           ++It)
        if (isUnmodeledRelocationHazard(*It, MSSA))
          return false;
      continue;
    }

    for (Instruction &I : *BB)
      if (isUnmodeledRelocationHazard(I, MSSA))
        return false;

    for (BasicBlock *Pred : predecessors(BB)) {
      if (!L->contains(Pred))
        return false;
      Worklist.push_back(Pred);
    }
  }
  return ReachedPoll;
}

struct HeaderPhiState {
  PHINode *Phi;
  Value *PreheaderValue;
  Value *LatchValue;
};

enum class PrimaryExitValueKind {
  LoopInvariant,
  ResumeIV,
  LiftedRecurrence,
};

struct PrimaryExitPhiState {
  PHINode *Phi;
  Value *IncomingValue;
  PrimaryExitValueKind Kind;
  unsigned RecurrenceIndex;
};

struct InclusiveExitPhiIncoming {
  PHINode *Phi;
  BasicBlock *ExitingBB;
  Value *IncomingValue;
};

struct InclusiveRuntimeGuard {
  ICmpInst::Predicate Predicate;
  ICmpInst::Predicate FirstIterationPredicate;
  APInt Bound;
  SmallVector<InclusiveExitPhiIncoming, 8> ExitPhiIncomings;
};

struct StripMinePlan {
  Loop *L;
  StripMineShape Shape;
  PHINode *IVPhi;
  ICmpInst *ExitCmp;
  CallInst *PollToMove;
  SmallVector<CallInst *, 4> AllPolls;
  SmallVector<PHINode *, 4> LiftedHeaderPhis;
  SmallVector<HeaderPhiState, 4> HeaderPhis;
  SmallVector<PrimaryExitPhiState, 4> PrimaryExitPhis;
  SmallVector<DeoptBoundaryValue, 8> DeoptBoundaryValues;
  std::optional<InclusiveRuntimeGuard> RuntimeGuard;
  APInt AbsStepN;
  bool IsSigned;
  uint64_t ChunkIters;
  Value *InitVal;
  Value *Limit;

  /// Pre-condition re-check queued before applying: this plan still matches the
  /// IR (loop/header/latch/exiting/exit identity, exit-branch wiring, poll
  /// parents, the IV-phi/limit/exit-cmp the relocation gates on, and the
  /// primary/runtime-guard exit-phi incomings). Sibling-plan application can
  /// invalidate a queued plan; each plan validates itself before it applies
  /// (C2's two-phase analyze-then-mutate pattern, guarded here against
  /// interference).
  bool stillStructurallyValid(LoopInfo &LI, DominatorTree &DT) const;
};

bool isSafeToVersionInclusiveLoop(Loop *L) {
  if (!L->isSafeToClone())
    return false;

  SmallVector<BasicBlock *, 4> ExitBlocks;
  L->getUniqueExitBlocks(ExitBlocks);
  for (BasicBlock *ExitBB : ExitBlocks) {
    auto It = ExitBB->getFirstNonPHIIt();
    if (It != ExitBB->end() && It->isEHPad())
      return false;
  }

  for (BasicBlock *BB : L->blocks()) {
    for (Instruction &I : *BB) {
      if (I.getType()->isTokenTy() && I.isUsedOutsideOfBlock(BB))
        return false;
      auto *CB = dyn_cast<CallBase>(&I);
      if (!CB)
        continue;
      if (isa<InvokeInst>(CB) || CB->isConvergent() ||
          CB->getAttributes()
              .getFnAttr(jeandle::Attribute::StatepointID)
              .isValid())
        return false;
    }
  }
  return true;
}

std::optional<StripMinePlan>
buildStripMinePlanWithIV(Loop *L, const IVInfo &IV, ICmpInst *ExitCmp,
                         CallInst *PollToMove, ArrayRef<CallInst *> AllPolls,
                         MemorySSA &MSSA, DominatorTree &DT,
                         ScalarEvolution &SE, bool AllowRuntimeVersioning) {
  auto MaybeShape = checkStripMineShape(L, IV, ExitCmp, SE);
  if (!MaybeShape) {
    LLVM_DEBUG(dbgs() << "  reject " << L->getHeader()->getName()
                      << ": unsupported loop shape\n");
    return std::nullopt;
  }
  StripMineShape Shape = *MaybeShape;

  if (!memoryStateMatchesBackedge(PollToMove, L, Shape.Header, Shape.Latch,
                                  MSSA)) {
    LLVM_DEBUG(dbgs() << "  reject " << L->getHeader()->getName()
                      << ": poll is not the backedge memory state\n");
    return std::nullopt;
  }
  if (!hasNoUnmodeledRelocationHazardAfterPoll(PollToMove, L, Shape.Latch,
                                               MSSA)) {
    LLVM_DEBUG(dbgs() << "  reject " << L->getHeader()->getName()
                      << ": unmodeled relocation hazard after poll\n");
    return std::nullopt;
  }
  auto DeoptBoundaryValues =
      analyzeDeoptBoundaryValues(PollToMove, L, Shape.Header, Shape.Latch);
  if (!DeoptBoundaryValues) {
    LLVM_DEBUG(dbgs() << "  reject " << L->getHeader()->getName()
                      << ": deopt state is not a batch boundary\n");
    return std::nullopt;
  }

  uint64_t N = jeandle::getLoopStripMiningIter();
  if (N < 2) {
    LLVM_DEBUG(dbgs() << "  reject " << L->getHeader()->getName()
                      << ": chunk budget below 2\n");
    return std::nullopt;
  }

  Type *Ty = IV.Phi->getType();
  Value *InitVal = IV.Phi->getIncomingValueForBlock(Shape.Preheader);
  Value *Limit = ExitCmp->getOperand(Shape.LimitOperandIdx);

  // Per-batch stride = |step| * Steps, where an inclusive predicate runs one
  // extra iteration so it advances Steps = N-1 (strict advances N). Compute it
  // in a wide value and bail unless it fits the IV type as a positive bound:
  // a narrow IV (or a chunk budget too large for the type) would otherwise
  // overflow the clamp arithmetic — truncating to a smaller or zero stride and,
  // at stride zero, spinning the outer loop forever. Bailing keeps such loops
  // un-mined (they retain their poll) rather than miscompiled.
  unsigned BitWidth = Ty->getIntegerBitWidth();
  uint64_t Steps = Shape.Inclusive ? N - 1 : N;
  bool IsSigned = ICmpInst::isSigned(Shape.ContinuePredicate);
  APInt WideStride =
      IV.Step.abs().zext(BitWidth + StripMineStrideOverflowWidenBits) *
      APInt(BitWidth + StripMineStrideOverflowWidenBits, Steps,
            /*isSigned=*/false);
  if (WideStride.isZero() ||
      WideStride.getActiveBits() + (IsSigned ? 1 : 0) > BitWidth) {
    LLVM_DEBUG(dbgs() << "  reject " << L->getHeader()->getName()
                      << ": batch stride overflows IV type\n");
    return std::nullopt;
  }
  APInt AbsStepN = WideStride.trunc(BitWidth);

  // The IV must not wrap inside a poll-free batch. A pre-tested outer may use
  // facts established at loop entry; a post-tested outer executes its first
  // batch unconditionally and therefore requires recurrence-level no-wrap.
  const SCEV *LimitS = SE.getSCEV(Limit);
  const Instruction *LoopEntryCtx = Shape.Header->getTerminator();
  bool HasRecurrenceNoWrap =
      IsSigned ? IV.AR->hasNoSignedWrap() : IV.AR->hasNoUnsignedWrap();
  std::optional<InclusiveRuntimeGuard> RuntimeGuard;
  if (!Shape.Inclusive) {
    bool HasStableInit = isGuaranteedNotToBeUndefOrPoison(InitVal);
    bool HasStableLimit = isGuaranteedNotToBeUndefOrPoison(Limit);
    bool HasValueIndependentNoWrap =
        HasRecurrenceNoWrap ||
        (Shape.FirstIterationGuaranteed && IV.Step.abs().isOne());
    // An entry guard over an undef-dependent value does not constrain a later
    // freeze of that value. Only accept unstable operands when no-wrap follows
    // from the step/recurrence itself; applyStripMinePlan then freezes each
    // operand once before duplicating it across the outer and inner tests.
    if ((!HasStableInit || !HasStableLimit) && !HasValueIndependentNoWrap) {
      LLVM_DEBUG(dbgs() << "  reject " << L->getHeader()->getName()
                        << ": cannot prove exclusive no-wrap\n");
      return std::nullopt;
    }
    bool CanProveNoWrap =
        Shape.FirstIterationGuaranteed
            ? canProveExclusiveNoWrap(IV.AR, IV.Step, LimitS, LoopEntryCtx,
                                      IsSigned, Shape.Increasing, SE)
            : HasRecurrenceNoWrap;
    if (!CanProveNoWrap) {
      LLVM_DEBUG(dbgs() << "  reject " << L->getHeader()->getName()
                        << ": cannot prove exclusive no-wrap\n");
      return std::nullopt;
    }
  } else {
    // The clamp and loop test use these operands separately. A SCEV range does
    // not make transitive uses of an undef-dependent SSA value agree.
    bool HasStableInit = isGuaranteedNotToBeUndefOrPoison(InitVal);
    bool HasStableLimit = isGuaranteedNotToBeUndefOrPoison(Limit);
    bool CanProveNoWrap = Shape.FirstIterationGuaranteed
                              ? canProveInclusiveNoWrap(
                                    IV.AR, IV.Step, Limit, LimitS, LoopEntryCtx,
                                    IsSigned, Shape.Increasing, SE)
                              : HasStableLimit && HasRecurrenceNoWrap;
    if (!HasStableInit || !CanProveNoWrap) {
      SmallVector<InclusiveExitPhiIncoming, 8> ExitPhiIncomings;
      SmallVector<BasicBlock *, 4> ExitBlocks;
      L->getUniqueExitBlocks(ExitBlocks);
      bool HasVersionableExits = L->hasDedicatedExits();
      for (BasicBlock *ExitBB : ExitBlocks) {
        for (PHINode &Phi : ExitBB->phis()) {
          for (unsigned I = 0; I < Phi.getNumIncomingValues(); ++I) {
            BasicBlock *ExitingBB = Phi.getIncomingBlock(I);
            if (!L->contains(ExitingBB)) {
              HasVersionableExits = false;
              break;
            }
            ExitPhiIncomings.push_back(
                {&Phi, ExitingBB, Phi.getIncomingValue(I)});
          }
          if (!HasVersionableExits)
            break;
        }
        if (!HasVersionableExits)
          break;
      }
      bool IsSupportedRuntimeShape =
          AllowRuntimeVersioning && HasVersionableExits &&
          isSafeToVersionInclusiveLoop(L) && IsSigned &&
          !IV.Step.isMinSignedValue() && IV.Phi->getType()->isIntegerTy(32) &&
          !Shape.Latch->getTerminator()->getMetadata(InclusiveSlowPathMD);
      if (!IsSupportedRuntimeShape) {
        LLVM_DEBUG(dbgs() << "  reject " << L->getHeader()->getName()
                          << ": inclusive loop not versionable\n");
        return std::nullopt;
      }

      APInt GuardBound = Shape.Increasing
                             ? APInt::getSignedMaxValue(/*numBits=*/32)
                             : APInt::getSignedMinValue(/*numBits=*/32);
      if (Shape.Increasing) {
        GuardBound -= IV.Step;
        GuardBound += 1;
      } else {
        GuardBound += IV.Step.abs();
        GuardBound -= 1;
      }
      RuntimeGuard = InclusiveRuntimeGuard{
          Shape.Increasing ? ICmpInst::ICMP_SLT : ICmpInst::ICMP_SGT,
          Shape.Increasing ? ICmpInst::ICMP_SLE : ICmpInst::ICMP_SGE,
          GuardBound, std::move(ExitPhiIncomings)};
    }
  }

  // Every non-IV header phi is a recurrence that must continue across batches,
  // so all of them are threaded through the outer loop — not only those that
  // leak out via an exit phi.
  SmallVector<PHINode *, 4> LiftedHeaderPhis;
  for (PHINode &Phi : Shape.Header->phis())
    if (&Phi != IV.Phi)
      LiftedHeaderPhis.push_back(&Phi);

  // Pre-mutation validation: every value leaking out through an exit LCSSA phi
  // must be representable at the selected outer-loop exit. Record the exact
  // recurrence whose latch value supplies each non-invariant incoming; a value
  // can also be a different header phi in cyclic recurrences, so its SSA
  // identity alone does not preserve that role.
  SmallVector<PrimaryExitPhiState, 4> PrimaryExitPhis;
  for (PHINode &Phi : Shape.ExitBB->phis()) {
    int Idx = Phi.getBasicBlockIndex(Shape.ExitingBB);
    if (Idx < 0)
      continue;
    Value *V = Phi.getIncomingValue(Idx);
    if (L->isLoopInvariant(V)) {
      PrimaryExitPhis.push_back(
          {&Phi, V, PrimaryExitValueKind::LoopInvariant, 0});
      continue;
    }
    if (V == Shape.ResumeIV) {
      PrimaryExitPhis.push_back({&Phi, V, PrimaryExitValueKind::ResumeIV, 0});
      continue;
    }
    PHINode *HPhi = getHeaderPhiForLatchValue(V, Shape.Header, Shape.Latch);
    if (!HPhi || HPhi == IV.Phi) {
      LLVM_DEBUG(dbgs() << "  reject " << L->getHeader()->getName()
                        << ": unsupported exit phi\n");
      return std::nullopt;
    }
    auto It = llvm::find(LiftedHeaderPhis, HPhi);
    assert(It != LiftedHeaderPhis.end() &&
           "validated recurrence must be lifted");
    PrimaryExitPhis.push_back(
        {&Phi, V, PrimaryExitValueKind::LiftedRecurrence,
         static_cast<unsigned>(It - LiftedHeaderPhis.begin())});
  }

  SmallVector<HeaderPhiState, 4> HeaderPhis;
  for (PHINode &Phi : Shape.Header->phis())
    HeaderPhis.push_back({&Phi, Phi.getIncomingValueForBlock(Shape.Preheader),
                          Phi.getIncomingValueForBlock(Shape.Latch)});

  return StripMinePlan{L,
                       Shape,
                       IV.Phi,
                       ExitCmp,
                       PollToMove,
                       SmallVector<CallInst *, 4>(AllPolls),
                       std::move(LiftedHeaderPhis),
                       std::move(HeaderPhis),
                       std::move(PrimaryExitPhis),
                       std::move(*DeoptBoundaryValues),
                       std::move(RuntimeGuard),
                       AbsStepN,
                       IsSigned,
                       N,
                       InitVal,
                       Limit};
}

std::optional<StripMinePlan>
buildStripMinePlan(Loop *L, LoopInfo &LI, DominatorTree &DT,
                   ScalarEvolution &SE, MemorySSA &MSSA,
                   bool AllowRuntimeVersioning = false) {
  if (!L->isInnermost()) {
    LLVM_DEBUG(dbgs() << "  reject " << L->getHeader()->getName()
                      << ": not innermost\n");
    return std::nullopt;
  }
  jeandle::LoopSafepointFacts Facts = jeandle::LoopSafepointFacts::get(*L, SE);
  // A loop whose symbolic maximum backedge count is below the shared budget
  // already meets the short-loop policy and needs no outer loop.
  if (Facts.IsWithinBudget) {
    LLVM_DEBUG(dbgs() << "  reject " << L->getHeader()->getName()
                      << ": within budget (short loop)\n");
    return std::nullopt;
  }
  if (!L->isLCSSAForm(DT) || !L->getLoopLatch() ||
      L->getLoopLatch()->getTerminator()->getMetadata(InclusiveSlowPathMD)) {
    LLVM_DEBUG(dbgs() << "  reject " << L->getHeader()->getName()
                      << ": not in LCSSA/simplify form or slow-path clone\n");
    return std::nullopt;
  }

  // A loop that reaches a guaranteed-safepoint call on every iteration needs
  // no outer loop: C2 declines to strip-mine loops with calls
  // (is_counted_loop's !loop->_has_call) and just drops the back-edge poll.
  // Skip the wrap here and let the following deletion pass erase the poll as
  // call-covered.
  if (jeandle::hasGuaranteedCallCoverage(*L, DT)) {
    LLVM_DEBUG(
        dbgs() << "  reject " << L->getHeader()->getName()
               << ": loop already reaches a guaranteed-safepoint call\n");
    return std::nullopt;
  }

  SmallVector<CallInst *, 4> Polls = collectBackEdgePolls(L, LI, DT);
  if (Polls.empty()) {
    LLVM_DEBUG(dbgs() << "  reject " << L->getHeader()->getName()
                      << ": no backedge poll\n");
    return std::nullopt;
  }
  jeandle::AncestorPollRequirements AncestorRequirements =
      jeandle::computeAncestorPollRequirements(*L, LI, DT, SE);
  for (CallInst *P : Polls)
    if (AncestorRequirements.isRequired(*P, DT)) {
      LLVM_DEBUG(dbgs() << "  reject " << L->getHeader()->getName()
                        << ": backedge poll required by an ancestor loop\n");
      return std::nullopt;
    }

  // Select the poll closest to the latch on the dominator chain, and the last
  // poll in that block. This is independent of Loop::blocks() traversal order
  // and matches the keep-one policy used by poll elimination.
  CallInst *PollToMove = findRelocationCandidate(L, LI, DT);
  if (!PollToMove) {
    LLVM_DEBUG(dbgs() << "  reject " << L->getHeader()->getName()
                      << ": no relocation candidate poll\n");
    return std::nullopt;
  }

  ICmpInst *Cmp = L->getLatchCmpInst();
  if (!Cmp || !isAcceptablePredicate(Cmp->getPredicate())) {
    LLVM_DEBUG(dbgs() << "  reject " << L->getHeader()->getName()
                      << ": no supported latch compare\n");
    return std::nullopt;
  }
  auto IV = findIntInduction(L, Cmp, SE);
  if (!IV) {
    LLVM_DEBUG(dbgs() << "  reject " << L->getHeader()->getName()
                      << ": no canonical integer induction\n");
    return std::nullopt;
  }
  auto Plan = buildStripMinePlanWithIV(L, *IV, Cmp, PollToMove, Polls, MSSA, DT,
                                       SE, AllowRuntimeVersioning);
  if (Plan && AllowRuntimeVersioning && !Plan->RuntimeGuard) {
    LLVM_DEBUG(dbgs() << "  reject " << L->getHeader()->getName()
                      << ": versioning declined (provably no-wrap)\n");
    return std::nullopt;
  }
  return Plan;
}

bool StripMinePlan::stillStructurallyValid(LoopInfo &LI,
                                           DominatorTree &DT) const {
  if (!L->isInnermost() || L->getHeader() != Shape.Header ||
      L->getLoopPreheader() != Shape.Preheader ||
      L->getLoopLatch() != Shape.Latch || LI.getLoopFor(Shape.Header) != L ||
      !L->contains(Shape.ExitingBB) || !L->isLCSSAForm(DT))
    return false;
  // The surgery reroutes the preheader's plain branch to the header; it must
  // still be one (the shape check required it at plan time).
  auto *PreheaderBr = dyn_cast<BranchInst>(Shape.Preheader->getTerminator());
  if (!PreheaderBr || PreheaderBr->getNumSuccessors() != 1 ||
      PreheaderBr->getSuccessor(0) != Shape.Header)
    return false;
  if (!jeandle::isSafepointPoll(*PollToMove) || !PollToMove->getParent() ||
      LI.getLoopFor(PollToMove->getParent()) != L ||
      !DT.dominates(PollToMove->getParent(), Shape.Latch))
    return false;
  if (ExitCmp->getParent() != Shape.ExitingBB || !ExitCmp->hasOneUse() ||
      ExitCmp->getOperand(Shape.LimitOperandIdx) != Limit ||
      ExitCmp->getOperand(1 - Shape.LimitOperandIdx) != Shape.ResumeIV ||
      Shape.ExitingBr->getParent() != Shape.ExitingBB ||
      Shape.ExitingBr->getCondition() != ExitCmp ||
      Shape.ExitingBr->getSuccessor(Shape.ExitSuccessorIdx) != Shape.ExitBB)
    return false;
  for (CallInst *P : AllPolls)
    if (!jeandle::isSafepointPoll(*P) || !P->getParent() ||
        LI.getLoopFor(P->getParent()) != L)
      return false;
  for (const HeaderPhiState &State : HeaderPhis) {
    int PreheaderIdx = State.Phi->getBasicBlockIndex(Shape.Preheader);
    int LatchIdx = State.Phi->getBasicBlockIndex(Shape.Latch);
    if (PreheaderIdx < 0 || LatchIdx < 0 ||
        State.Phi->getIncomingValue(PreheaderIdx) != State.PreheaderValue ||
        State.Phi->getIncomingValue(LatchIdx) != State.LatchValue)
      return false;
  }
  for (const PrimaryExitPhiState &State : PrimaryExitPhis) {
    int Idx = State.Phi->getBasicBlockIndex(Shape.ExitingBB);
    if (Idx < 0 || State.Phi->getIncomingValue(Idx) != State.IncomingValue)
      return false;
    switch (State.Kind) {
    case PrimaryExitValueKind::LoopInvariant:
      if (!L->isLoopInvariant(State.IncomingValue))
        return false;
      break;
    case PrimaryExitValueKind::ResumeIV:
      if (State.IncomingValue != Shape.ResumeIV)
        return false;
      break;
    case PrimaryExitValueKind::LiftedRecurrence:
      if (State.RecurrenceIndex >= LiftedHeaderPhis.size() ||
          LiftedHeaderPhis[State.RecurrenceIndex]->getIncomingValueForBlock(
              Shape.Latch) != State.IncomingValue)
        return false;
      break;
    }
  }
  auto OB = PollToMove->getOperandBundle(LLVMContext::OB_deopt);
  if (OB) {
    if (OB->Inputs.size() != DeoptBoundaryValues.size())
      return false;
    for (size_t I = 0; I < DeoptBoundaryValues.size(); ++I) {
      if (OB->Inputs[I].get() != DeoptBoundaryValues[I].Original)
        return false;
      const DeoptBoundaryValue &Boundary = DeoptBoundaryValues[I];
      if (!Boundary.OriginalRoot) {
        if (Boundary.BoundaryBase || Boundary.LatchValue ||
            !Boundary.Casts.empty())
          return false;
        continue;
      }
      Value *Root = Boundary.Original;
      for (CastInst *Cast : Boundary.Casts) {
        if (Root != Cast)
          return false;
        Root = Cast->getOperand(0);
      }
      if (Root != Boundary.OriginalRoot)
        return false;
      if (Boundary.LatchValue) {
        if (Boundary.BoundaryBase != Boundary.LatchValue ||
            Root != Boundary.LatchValue ||
            !isHeaderPhiLatchValue(Root, Shape.Header, Shape.Latch))
          return false;
        continue;
      }
      if (Root == Boundary.BoundaryBase) {
        if (!L->isLoopInvariant(Root))
          return false;
        continue;
      }
      auto *Phi = dyn_cast<PHINode>(Root);
      if (!Phi || getLoopInvariantSelfRecurrenceInitial(Phi, L, Shape.Header,
                                                        Shape.Latch) !=
                      Boundary.BoundaryBase)
        return false;
    }
  } else if (!DeoptBoundaryValues.empty()) {
    return false;
  }
  if (RuntimeGuard) {
    if (!isSafeToVersionInclusiveLoop(L) || !L->hasDedicatedExits())
      return false;
    for (const InclusiveExitPhiIncoming &Incoming :
         RuntimeGuard->ExitPhiIncomings) {
      int Idx = Incoming.Phi->getBasicBlockIndex(Incoming.ExitingBB);
      if (Idx < 0 ||
          Incoming.Phi->getIncomingValue(Idx) != Incoming.IncomingValue)
        return false;
    }
  }
  return true;
}

void replaceLoopUses(Loop *L, Value *From, Value *To) {
  if (From == To)
    return;
  if (isa<Constant>(From)) {
    // Constants have no use list to filter: rewrite in-loop uses directly.
    // Freezing undef/poison unifies every use to one frozen value — a valid
    // refinement that keeps all duplicated uses in agreement.
    for (BasicBlock *BB : L->blocks())
      for (Instruction &I : *BB)
        I.replaceUsesOfWith(From, To);
    return;
  }
  From->replaceUsesWithIf(To, [L](Use &U) {
    auto *I = dyn_cast<Instruction>(U.getUser());
    return I && L->contains(I);
  });
}

struct FrozenOperands {
  Value *StableInit = nullptr;
  Value *StableLimit = nullptr;
};

// Freeze InitVal/Limit when either may be undef/poison so the duplicated tests
// in the outer-loop (strip mining) or the cloned slow path (inclusive versioning)
// agree on a single stable value. Operands already known non-undef are returned
// unchanged. `B` must be positioned where the freeze should materialize (the
// preheader terminator for strip mining, the versioning check block for inclusive
// versioning); `Prefix` selects the freeze value names ("exclusive.*" /
// "inclusive.*"). In-loop uses of a frozen operand are rewritten to the frozen
// value. Shared by applyStripMinePlan and applyInclusiveLoopVersioningPlan.
static FrozenOperands freezeLoopOperands(Loop *L, Value *InitVal, Value *Limit,
                                         IRBuilder<> &B, StringRef Prefix) {
  Value *StableLimit =
      isGuaranteedNotToBeUndefOrPoison(Limit)
          ? Limit
          : B.CreateFreeze(Limit, Prefix + ".limit.fr");
  Value *StableInit =
      InitVal == Limit
          ? StableLimit
          : (isGuaranteedNotToBeUndefOrPoison(InitVal)
                 ? InitVal
                 : B.CreateFreeze(InitVal, Prefix + ".start.fr"));
  replaceLoopUses(L, Limit, StableLimit);
  replaceLoopUses(L, InitVal, StableInit);
  return {StableInit, StableLimit};
}

void applyInclusiveLoopVersioningPlan(StripMinePlan &Plan, LoopInfo &LI,
                                      DominatorTree &DT) {
  assert(Plan.RuntimeGuard && "versioning plan must carry a runtime guard");
  Loop *FastLoop = Plan.L;
  StripMineShape &Shape = Plan.Shape;
  Function *F = Shape.Header->getParent();

  BasicBlock *CheckBB = Shape.Preheader;
  BasicBlock *FastPreheader =
      SplitBlock(CheckBB, CheckBB->getTerminator(), &DT, &LI, nullptr,
                 Shape.Header->getName() + ".inclusive.fast.ph");

  IRBuilder<> CheckBuilder(CheckBB->getTerminator());
  // Freeze only operands that may be undef/poison; stable operands (constants,
  // noundef values) are read directly by the guard and the duplicated tests.
  auto [StableInit, StableLimit] = freezeLoopOperands(
      FastLoop, Plan.InitVal, Plan.Limit, CheckBuilder, "inclusive");

  ValueToValueMapTy VMap;
  SmallVector<BasicBlock *, 8> SlowBlocks;
  Loop *SlowLoop =
      cloneLoopWithPreheader(FastPreheader, CheckBB, FastLoop, VMap,
                             ".inclusive.slow", &LI, &DT, SlowBlocks);
  remapInstructionsInBlocks(SlowBlocks, VMap);

  auto *SlowPreheader = cast<BasicBlock>(VMap[FastPreheader]);
  for (const InclusiveExitPhiIncoming &Incoming :
       Plan.RuntimeGuard->ExitPhiIncomings) {
    auto *SlowExitingBB = cast<BasicBlock>(VMap[Incoming.ExitingBB]);
    Value *SlowValue = Incoming.IncomingValue;
    if (auto It = VMap.find(SlowValue); It != VMap.end())
      SlowValue = It->second;
    Incoming.Phi->addIncoming(SlowValue, SlowExitingBB);
  }

  Instruction *OldTerm = CheckBB->getTerminator();
  BasicBlock *NoWrapCheckBB = BasicBlock::Create(
      F->getContext(), Shape.Header->getName() + ".inclusive.no_wrap.check", F,
      SlowPreheader);
  if (Loop *ParentL = FastLoop->getParentLoop())
    ParentL->addBasicBlockToLoop(NoWrapCheckBB, LI);
  IRBuilder<> B(NoWrapCheckBB);
  const InclusiveRuntimeGuard &Guard = *Plan.RuntimeGuard;
  Value *NoWrap =
      B.CreateICmp(Guard.Predicate, StableLimit,
                   ConstantInt::get(StableLimit->getType(), Guard.Bound),
                   "inclusive.no_wrap");
  B.CreateCondBr(NoWrap, FastPreheader, SlowPreheader);

  IRBuilder<> EntryBuilder(OldTerm);
  Value *FirstIteration =
      EntryBuilder.CreateICmp(Guard.FirstIterationPredicate, StableInit,
                              StableLimit, "inclusive.first_iteration");
  EntryBuilder.CreateCondBr(FirstIteration, NoWrapCheckBB, SlowPreheader);
  OldTerm->eraseFromParent();

  SlowLoop->getLoopLatch()->getTerminator()->setMetadata(
      InclusiveSlowPathMD, MDNode::get(F->getContext(), {}));

  // Both versions initially retain their original polls. Re-form dedicated
  // exits before the next pass recomputes MemorySSA and strip-mines only the
  // guarded version. The NoWrapCheckBB / entry-guard construction above bypasses
  // DominatorTree maintenance, so re-baseline DT once before forming the exits;
  // formDedicatedExitBlocks then keeps DT current incrementally (it splits
  // predecessors through DT), so no second recalculate is needed.
  DT.recalculate(*F);
  formDedicatedExitBlocks(SlowLoop, &DT, &LI, nullptr, true);
  formDedicatedExitBlocks(FastLoop, &DT, &LI, nullptr, true);

  LLVM_DEBUG(dbgs() << "  inclusive-versioning: versioned "
                    << Shape.Header->getName()
                    << " (cloned slow path behind no-wrap guard)\n");
}

// Per-batch inner limit for a SIGNED counted loop, built as a C2-style
// residual-distance chunk in a 2*BW wide type:
//   Diff  = (Increasing ? Limit : OuterIV) - (Increasing ? OuterIV : Limit)
//   Chunk = trunc(smin(smax(Diff, 0), zext(StepN)))
//   Limit = OuterIV + Chunk (increasing) / OuterIV - Chunk (decreasing)
//
// This replaces sadd_sat/ssub_sat: ScalarEvolution does not model the signed
// saturating intrinsics (createSCEV falls through to getUnknown for them), so
// the old clamp left the inner loop's backedge-taken count as
// SCEVCouldNotCompute — defeating the unroll/vectorize that strip mining exists
// to enable. Every operation used here (sext, nsw sub, smax, smin, zext, trunc,
// nsw add/sub) is modeled by ScalarEvolution, so the inner trip count stays
// analyzable downstream.
//
// Widening the subtraction to 2*BW makes it overflow-free for any IV range:
// the difference of two BW-bit signed values always fits in 2*BW bits. That
// preserves the saturating-add behavior of never degenerating strip mining on
// extreme IV ranges (no perf cliff). chunk <= max(0, Diff) then bounds the
// IV-type add/sub to [OuterIV, Limit], so it is non-overflowing and safely
// carries nsw. NUW is intentionally not set: signed IV values may be negative.
static Value *emitSignedInnerLimit(IRBuilder<> &B, Value *OuterIV, Value *Limit,
                                   const APInt &AbsStepN, bool Increasing) {
  Type *IVTy = OuterIV->getType();
  unsigned BW = IVTy->getIntegerBitWidth();
  IntegerType *WideTy = IntegerType::get(B.getContext(), 2 * BW);

  Value *StepN = ConstantInt::get(IVTy, AbsStepN);
  Value *WideIV = B.CreateSExt(OuterIV, WideTy, "outer.iv.wide");
  Value *WideLim = B.CreateSExt(Limit, WideTy, "outer.limit.wide");
  Value *Diff = Increasing ? B.CreateNSWSub(WideLim, WideIV, "outer.batch.dist")
                           : B.CreateNSWSub(WideIV, WideLim, "outer.batch.dist");
  Value *ZeroW = ConstantInt::get(WideTy, 0);
  Value *Rem = B.CreateBinaryIntrinsic(Intrinsic::smax, Diff, ZeroW,
                                       /*FMFSource=*/nullptr, "outer.batch.rem");
  Value *StepNW =
      B.CreateZExt(StepN, WideTy, "outer.batch.stepn.wide");
  Value *ChunkW = B.CreateBinaryIntrinsic(Intrinsic::smin, Rem, StepNW,
                                          /*FMFSource=*/nullptr,
                                          "outer.batch.chunk.wide");
  Value *Chunk = B.CreateTrunc(ChunkW, IVTy, "outer.batch.chunk");
  return Increasing ? B.CreateNSWAdd(OuterIV, Chunk, "outer.inner.limit")
                    : B.CreateNSWSub(OuterIV, Chunk, "outer.inner.limit");
}

// Wrap `L` in a freshly-allocated outer loop so the nest becomes OuterL -> L,
// and register the new outer-loop blocks (OuterHeader, InnerEntry, OuterLatch)
// under OuterL along with L's existing blocks. OuterPH is the new outer loop's
// preheader: it is attached to L's original parent (or left at top level) and
// deliberately kept OUT of OuterL. No upstream utility builds this "wrap a loop
// in an outer loop" shape, so the reparenting is done by hand exactly as
// LoopInterchange and SimpleLoopUnswitch do; the assertions below pin the
// LoopInfo nest invariants the rest of the pass relies on. The caller
// recalculates the DominatorTree afterwards, so these structural checks do not
// require it.
static Loop *reparentAsOuterLoop(Loop *L, BasicBlock *OuterPH,
                                 BasicBlock *OuterHeader, BasicBlock *InnerEntry,
                                 BasicBlock *OuterLatch, LoopInfo &LI) {
  Loop *OuterL = LI.AllocateLoop();
  if (Loop *ParentL = L->getParentLoop()) {
    auto It = llvm::find(*ParentL, L);
    assert(It != ParentL->end() && "L not a child of its parent");
    ParentL->removeChildLoop(It);
    ParentL->addChildLoop(OuterL);
    ParentL->addBasicBlockToLoop(OuterPH, LI);
  } else {
    auto It = llvm::find(LI, L);
    assert(It != LI.end() && "L not a top-level loop");
    LI.removeLoop(It);
    LI.addTopLevelLoop(OuterL);
  }
  OuterL->addChildLoop(L);
  OuterL->addBasicBlockToLoop(OuterHeader, LI);
  OuterL->addBasicBlockToLoop(InnerEntry, LI);
  OuterL->addBasicBlockToLoop(OuterLatch, LI);
  for (BasicBlock *BB : L->blocks())
    OuterL->addBlockEntry(BB);

  assert(OuterL->contains(L) && "outer loop must contain the inner loop");
  assert(L->getParentLoop() == OuterL && "inner's parent must be the outer loop");
  assert(LI.getLoopFor(OuterHeader) == OuterL &&
         LI.getLoopFor(InnerEntry) == OuterL &&
         LI.getLoopFor(OuterLatch) == OuterL &&
         "outer body blocks must belong to the outer loop");
  assert(LI.getLoopFor(OuterPH) != OuterL &&
         "the outer preheader must stay outside the outer loop");
  assert(llvm::all_of(L->blocks(),
                      [&](BasicBlock *BB) { return OuterL->contains(BB); }) &&
         "every inner-loop block must be in the outer loop");
  return OuterL;
}

// Relocate the planned back-edge poll onto the outer back-edge, immediately
// before OuterBr: clone it with the deopt operands remapped to the outer
// recurrences, and tag the clone as the strip-mined poll. Latch-carried next
// values are remapped to the outer PHIs; optimizer-introduced cast chains are
// rebuilt from those outer values and cached in Remap. A loop-invariant latch
// value (e.g. a phi whose latch operand is a constant) is skipped: it needs no
// remap, and keying Remap on it would spuriously rewrite an unrelated but equal
// constant elsewhere in the deopt bundle. The bci/frame layout in the deopt
// bundle is carried over verbatim — no LLVM pass may synthesize a poll, only
// relocate one. The strip-mined-poll attribute is the contract the coverage
// verifier trusts without re-deriving the bound, and the marker the
// after-strip-mining poll elimination keys on; marking the poll itself means
// the marker cannot outlive the coverage it certifies.
static void relocatePollToOuterLatch(StripMinePlan &Plan, Value *OuterIVNext,
                                     ArrayRef<PHINode *> OuterReducNext,
                                     BranchInst *OuterBr) {
  Loop *L = Plan.L;
  const StripMineShape &Shape = Plan.Shape;
  CallInst *PollToMove = Plan.PollToMove;
  ArrayRef<PHINode *> LiftedHeaderPhis = Plan.LiftedHeaderPhis;

  DenseMap<Value *, Value *> Remap;
  auto addRemap = [&](Value *LatchVal, Value *Outer) {
    if (!L->isLoopInvariant(LatchVal))
      Remap[LatchVal] = Outer;
  };
  addRemap(Plan.IVPhi->getIncomingValueForBlock(Shape.Latch), OuterIVNext);
  for (size_t I = 0; I < LiftedHeaderPhis.size(); ++I)
    addRemap(LiftedHeaderPhis[I]->getIncomingValueForBlock(Shape.Latch),
             OuterReducNext[I]);
  SmallVector<OperandBundleDef, 1> Bundles;
  if (auto OB = PollToMove->getOperandBundle(LLVMContext::OB_deopt)) {
    assert(OB->Inputs.size() == Plan.DeoptBoundaryValues.size() &&
           "deopt boundary plan no longer matches the poll bundle");
    SmallVector<Value *, 8> Args;
    for (const DeoptBoundaryValue &Boundary : Plan.DeoptBoundaryValues) {
      if (!Boundary.OriginalRoot) {
        Args.push_back(Boundary.Original);
        continue;
      }

      Value *Remapped = Boundary.BoundaryBase;
      if (auto It = Remap.find(Boundary.BoundaryBase); It != Remap.end())
        Remapped = It->second;
      else
        assert(L->isLoopInvariant(Boundary.BoundaryBase) &&
               "planned boundary base has no outer value");
      for (CastInst *Cast : llvm::reverse(Boundary.Casts)) {
        if (auto Cached = Remap.find(Cast); Cached != Remap.end()) {
          Remapped = Cached->second;
          continue;
        }
        auto *OuterCast = cast<CastInst>(Cast->clone());
        OuterCast->setOperand(0, Remapped);
        OuterCast->setName(Cast->getName() + ".outer");
        OuterCast->insertBefore(OuterBr->getIterator());
        Remapped = OuterCast;
        Remap[Cast] = OuterCast;
      }
      Args.push_back(Remapped);
    }
    Bundles.emplace_back("deopt", Args);
  }
  auto *RelocatedPoll =
      CallBase::Create(PollToMove, Bundles, OuterBr->getIterator());
  RelocatedPoll->addFnAttr(Attribute::get(OuterBr->getContext(),
                                          jeandle::Attribute::StripMinedPoll));
}

// Rewrite the primary-exit LCSSA PHI incomings at the boundary where the
// selected outer skeleton exits. A pre-tested outer loop exposes its current
// recurrences at OuterHeader; a post-tested outer loop exposes the
// just-completed batch at OuterLatch. Use the recurrence role recorded by the
// plan: in a cyclic recurrence, the same SSA value can be both one header phi
// and another phi's latch value, but only the latter describes its value on
// this exit.
static void fixupPrimaryExitPhis(StripMinePlan &Plan, BasicBlock *OuterHeader,
                                 BasicBlock *OuterLatch, PHINode *OuterIV,
                                 PHINode *OuterIVNext,
                                 ArrayRef<PHINode *> OuterReducPhis,
                                 ArrayRef<PHINode *> OuterReducNext) {
  const StripMineShape &Shape = Plan.Shape;
  for (const PrimaryExitPhiState &State : Plan.PrimaryExitPhis) {
    PHINode *Phi = State.Phi;
    int Idx = Phi->getBasicBlockIndex(Shape.ExitingBB);
    assert(Idx >= 0 && Phi->getIncomingValue(Idx) == State.IncomingValue &&
           "primary exit phi no longer matches its plan");
    Phi->setIncomingBlock(Idx, Shape.FirstIterationGuaranteed ? OuterHeader
                                                              : OuterLatch);
    switch (State.Kind) {
    case PrimaryExitValueKind::LoopInvariant:
      break;
    case PrimaryExitValueKind::ResumeIV:
      Phi->setIncomingValue(Idx, Shape.FirstIterationGuaranteed ? OuterIV
                                                                : OuterIVNext);
      break;
    case PrimaryExitValueKind::LiftedRecurrence:
      assert(State.RecurrenceIndex < OuterReducPhis.size() &&
             "planned recurrence index out of range");
      Phi->setIncomingValue(Idx, Shape.FirstIterationGuaranteed
                                     ? OuterReducPhis[State.RecurrenceIndex]
                                     : OuterReducNext[State.RecurrenceIndex]);
      break;
    }
  }
}

// The blocks and recurrence PHIs of the outer wrapper loop built around the
// inner loop being strip-mined. The skeleton is created up front and filled in
// in phases (outer header, inner-entry clamp, outer latch), so the values are
// threaded through this frame rather than scattered as locals in the caller.
struct OuterLoopFrame {
  BasicBlock *OuterPH = nullptr;
  BasicBlock *OuterHeader = nullptr;
  BasicBlock *InnerEntry = nullptr;
  BasicBlock *OuterLatch = nullptr; // created empty, filled by buildOuterLatch
  PHINode *OuterIV = nullptr;
  PHINode *OuterIVNext = nullptr;
  SmallVector<PHINode *, 4> OuterReducPhis;
  SmallVector<PHINode *, 4> OuterReducNext;
  BranchInst *OuterBr = nullptr;
  Value *InnerLimit = nullptr;
};

// Create the four outer-loop blocks, reroute the inner preheader into the new
// outer preheader, and build the outer header: the outer IV phi, the lifted
// reduction phis (one per non-IV header phi), and the pre/post-tested entry
// branch. OuterLatch is created empty here so it lands in the right position in
// the function; buildOuterLatch fills it.
static void createOuterSkeleton(StripMinePlan &Plan, Function *F, Type *Ty,
                                Value *InitVal, Value *Limit,
                                OuterLoopFrame &Frame) {
  const StripMineShape &Shape = Plan.Shape;
  LLVMContext &Ctx = F->getContext();

  Frame.OuterPH =
      BasicBlock::Create(Ctx, Shape.Header->getName() + ".outer.ph", F);
  Frame.OuterHeader =
      BasicBlock::Create(Ctx, Shape.Header->getName() + ".outer", F);
  Frame.InnerEntry = BasicBlock::Create(
      Ctx, Shape.Header->getName() + ".outer.inner.entry", F);
  Frame.OuterLatch =
      BasicBlock::Create(Ctx, Shape.Header->getName() + ".outer.latch", F);

  auto *PHBr = cast<BranchInst>(Shape.Preheader->getTerminator());
  for (unsigned I = 0; I < PHBr->getNumSuccessors(); ++I)
    if (PHBr->getSuccessor(I) == Shape.Header)
      PHBr->setSuccessor(I, Frame.OuterPH);

  IRBuilder<> B(Frame.OuterPH);
  B.CreateBr(Frame.OuterHeader);

  B.SetInsertPoint(Frame.OuterHeader);
  Frame.OuterIV = B.CreatePHI(Ty, 2, "outer.iv");
  Frame.OuterIV->addIncoming(InitVal, Frame.OuterPH);
  for (PHINode *HPhi : Plan.LiftedHeaderPhis) {
    PHINode *OP = B.CreatePHI(HPhi->getType(), 2, HPhi->getName() + ".outer");
    OP->addIncoming(HPhi->getIncomingValueForBlock(Shape.Preheader), Frame.OuterPH);
    Frame.OuterReducPhis.push_back(OP);
  }
  if (Shape.FirstIterationGuaranteed) {
    // OuterCond is "continue the inner batch" so the br targets are fixed
    // regardless of the original branch polarity.
    Value *OuterCond =
        B.CreateICmp(Shape.ContinuePredicate, Frame.OuterIV, Limit, "outer.cond");
    B.CreateCondBr(OuterCond, Frame.InnerEntry, Shape.ExitBB);
  } else {
    // A latch-tested source loop executes once even when its continue
    // predicate is initially false. Preserve that behavior by entering the
    // first inner batch unconditionally and testing only at the outer latch.
    B.CreateBr(Frame.InnerEntry);
  }
}

// Fill InnerEntry with the per-batch limit clamp so a batch never exceeds N
// iterations while still respecting the real loop limit. The signed and
// unsigned paths differ only here:
//  - Unsigned loops keep the SCEV-modeled uadd_sat/usub_sat + select clamp.
//  - Signed loops use a residual-distance chunk (emitSignedInnerLimit):
//    sadd_sat/ssub_sat are NOT modeled by ScalarEvolution, so the old clamp
//    left the inner backedge-taken count as SCEVCouldNotCompute and defeated
//    the unroll/vectorize that strip mining exists to enable.
static void clampInnerLimit(StripMinePlan &Plan, Type *Ty, Value *Limit,
                            OuterLoopFrame &Frame) {
  const StripMineShape &Shape = Plan.Shape;
  IRBuilder<> B(Frame.InnerEntry);
  Value *StepN = ConstantInt::get(Ty, Plan.AbsStepN);
  Value *InnerLimit;
  if (!Plan.IsSigned) {
    Intrinsic::ID SatID =
        Shape.Increasing ? Intrinsic::uadd_sat : Intrinsic::usub_sat;
    Value *BatchEnd =
        B.CreateBinaryIntrinsic(SatID, Frame.OuterIV, StepN,
                                /*FMFSource=*/nullptr, "outer.batch.end");
    Value *KeepEnd =
        B.CreateICmp(Shape.ContinuePredicate, BatchEnd, Limit, "outer.cap.cond");
    InnerLimit = B.CreateSelect(KeepEnd, BatchEnd, Limit, "outer.inner.limit");
  } else {
    InnerLimit = emitSignedInnerLimit(B, Frame.OuterIV, Limit, Plan.AbsStepN,
                                      Shape.Increasing);
  }
  B.CreateBr(Shape.Header);
  Frame.InnerLimit = InnerLimit;
}

// Rewire the inner loop to run as one batch: repoint each header phi's
// preheader incoming at InnerEntry (fed by the outer recurrence), set the latch
// exit compare to the clamped per-batch limit, and redirect the exiting branch's
// exit edge to the outer latch so a completed batch feeds the next outer
// iteration instead of leaving the loop.
static void rewireInnerHeaderForBatch(StripMinePlan &Plan, OuterLoopFrame &Frame) {
  const StripMineShape &Shape = Plan.Shape;
  ArrayRef<PHINode *> LiftedHeaderPhis = Plan.LiftedHeaderPhis;

  int PHIdx = Plan.IVPhi->getBasicBlockIndex(Shape.Preheader);
  Plan.IVPhi->setIncomingBlock(PHIdx, Frame.InnerEntry);
  Plan.IVPhi->setIncomingValue(PHIdx, Frame.OuterIV);
  for (size_t I = 0; I < LiftedHeaderPhis.size(); ++I) {
    int Ix = LiftedHeaderPhis[I]->getBasicBlockIndex(Shape.Preheader);
    LiftedHeaderPhis[I]->setIncomingBlock(Ix, Frame.InnerEntry);
    LiftedHeaderPhis[I]->setIncomingValue(Ix, Frame.OuterReducPhis[I]);
  }

  Plan.ExitCmp->setOperand(Shape.LimitOperandIdx, Frame.InnerLimit);
  Shape.ExitingBr->setSuccessor(Shape.ExitSuccessorIdx, Frame.OuterLatch);
}

// Build the outer latch: the batch-boundary recurrence next-values (one input
// each, fed from the inner exiting block), the back-edge branch (a pre-tested
// outer loop returns unconditionally to the outer header; a post-tested one
// re-tests the continue predicate here), and the second incomings of the outer
// header phis that close the outer recurrence cycle.
static void buildOuterLatch(StripMinePlan &Plan, Type *Ty, Value *Limit,
                            OuterLoopFrame &Frame) {
  const StripMineShape &Shape = Plan.Shape;
  ArrayRef<PHINode *> LiftedHeaderPhis = Plan.LiftedHeaderPhis;

  IRBuilder<> B(Frame.OuterLatch);
  Frame.OuterIVNext = B.CreatePHI(Ty, 1, "outer.iv.next");
  Frame.OuterIVNext->addIncoming(Shape.ResumeIV, Shape.ExitingBB);
  for (PHINode *HPhi : LiftedHeaderPhis) {
    PHINode *NP =
        B.CreatePHI(HPhi->getType(), 1, HPhi->getName() + ".outer.next");
    NP->addIncoming(HPhi->getIncomingValueForBlock(Shape.Latch),
                    Shape.ExitingBB);
    Frame.OuterReducNext.push_back(NP);
  }
  if (Shape.FirstIterationGuaranteed) {
    Frame.OuterBr = B.CreateBr(Frame.OuterHeader);
  } else {
    Value *OuterCond =
        B.CreateICmp(Shape.ContinuePredicate, Frame.OuterIVNext, Limit, "outer.cond");
    Frame.OuterBr = B.CreateCondBr(OuterCond, Frame.OuterHeader, Shape.ExitBB);
  }
  Frame.OuterIV->addIncoming(Frame.OuterIVNext, Frame.OuterLatch);
  for (size_t I = 0; I < Frame.OuterReducPhis.size(); ++I)
    Frame.OuterReducPhis[I]->addIncoming(Frame.OuterReducNext[I],
                                         Frame.OuterLatch);
}

void applyStripMinePlan(StripMinePlan &Plan, LoopInfo &LI, DominatorTree &DT,
                        ScalarEvolution &SE) {
  Loop *L = Plan.L;
  StripMineShape &Shape = Plan.Shape;
  CallInst *PollToMove = Plan.PollToMove;
  const APInt &AbsStepN = Plan.AbsStepN;
  uint64_t N = Plan.ChunkIters;
  Value *InitVal = Plan.InitVal;
  Value *Limit = Plan.Limit;

  Function *F = Shape.Header->getParent();
  Type *Ty = Plan.IVPhi->getType();

  if (!Shape.Inclusive && (!isGuaranteedNotToBeUndefOrPoison(InitVal) ||
                           !isGuaranteedNotToBeUndefOrPoison(Limit))) {
    IRBuilder<> StableBuilder(Shape.Preheader->getTerminator());
    auto [StableInit, StableLimit] =
        freezeLoopOperands(L, InitVal, Limit, StableBuilder, "exclusive");
    Limit = StableLimit;
    InitVal = StableInit;
  }

  OuterLoopFrame Frame;
  createOuterSkeleton(Plan, F, Ty, InitVal, Limit, Frame);
  clampInnerLimit(Plan, Ty, Limit, Frame);
  rewireInnerHeaderForBatch(Plan, Frame);
  buildOuterLatch(Plan, Ty, Limit, Frame);

  // Relocate the back-edge poll onto the outer back-edge (cloned, with its
  // deopt state remapped to the outer recurrences and tagged as the
  // strip-mined poll that certifies the inner loop's bounded coverage).
  relocatePollToOuterLatch(Plan, Frame.OuterIVNext, Frame.OuterReducNext,
                           Frame.OuterBr);

  // Rewrite the primary-exit LCSSA PHI incomings to the outer skeleton's exit
  // boundary, using the recurrence role recorded by the plan.
  fixupPrimaryExitPhis(Plan, Frame.OuterHeader, Frame.OuterLatch, Frame.OuterIV,
                       Frame.OuterIVNext, Frame.OuterReducPhis,
                       Frame.OuterReducNext);

  // Drop the selected back-edge poll after cloning it to the outer backedge.
  // The subsequent poll-elimination stage removes any other inner-loop polls
  // only after validating the complete strip-mined structure.
  PollToMove->eraseFromParent();

  // Maintain analyses by hand (no LPMUpdater): reparent the nest so it becomes
  // OuterL -> L, add the new blocks, then rebuild DT and drop stale SCEV. The
  // outer loop is not in this run's loop snapshot, so it is not revisited; its
  // poll carries the coverage marker against later passes.
  Loop *OuterL = reparentAsOuterLoop(L, Frame.OuterPH, Frame.OuterHeader,
                                     Frame.InnerEntry, Frame.OuterLatch, LI);

  DT.recalculate(*F);
  SE.forgetLoop(L);
  SE.forgetTopmostLoop(L);
  SE.forgetBlockAndLoopDispositions();

  // MemorySSA is deliberately NOT updated: plans validate their memory state
  // against the pre-mutation MSSA at build time, no MSSA query happens after a
  // mutation inside this pass, and PreservedAnalyses::none() forces a rebuild
  // for the next consumer. (The erased poll leaves a dangling MemoryAccess in
  // the stale MSSA; nothing may query it.)
  LLVM_DEBUG(dbgs() << "  strip-mine: wrapped loop " << Shape.Header->getName()
                    << " (N=" << N << ", inclusive=" << Shape.Inclusive
                    << ", batch-stride=" << AbsStepN.getLimitedValue()
                    << ", relocated poll to outer back-edge)\n");
}

} // namespace

void SafepointStripMining::printPipeline(
    raw_ostream &OS, function_ref<StringRef(StringRef)> MapClassName2PassName) {
  static_cast<PassInfoMixin<SafepointStripMining> *>(this)->printPipeline(
      OS, MapClassName2PassName);
  OS << '<';
  switch (Mode) {
  case SafepointStripMiningMode::InclusiveLoopVersioning:
    OS << "inclusive-loop-versioning";
    break;
  case SafepointStripMiningMode::StripMining:
    OS << "strip-mining";
    break;
  }
  if (DeferEmptyLoopDeletion)
    OS << ";defer-empty-loop-deletion";
  OS << '>';
}

PreservedAnalyses SafepointStripMining::run(Function &F,
                                            FunctionAnalysisManager &AM) {
  if (!jeandle::isSafepointEliminationEnabled() ||
      !jeandle::isRootJavaMethodFunction(F) || !jeandle::isStripMiningEnabled())
    return PreservedAnalyses::all();

  if (Mode == SafepointStripMiningMode::InclusiveLoopVersioning &&
      !jeandle::isInclusiveLoopVersioningEnabled())
    return PreservedAnalyses::all();

  LLVM_DEBUG(dbgs() << "strip-mining<" << modeName(Mode) << "> running on "
                    << F.getName() << "\n");

  auto &LI = AM.getResult<LoopAnalysis>(F);
  ReversePostOrderTraversal<const Function *> RPOT(&F);
  if (containsIrreducibleCFG<const BasicBlock *>(RPOT, LI)) {
    LLVM_DEBUG(dbgs() << "strip-mining<" << modeName(Mode)
                      << ">: irreducible CFG in " << F.getName()
                      << ", all polls preserved\n");
    return PreservedAnalyses::all();
  }

  auto &DT = AM.getResult<DominatorTreeAnalysis>(F);
  auto &SE = AM.getResult<ScalarEvolutionAnalysis>(F);
  auto &MSSA = AM.getResult<MemorySSAAnalysis>(F).getMSSA();
  SmallVector<Loop *, 8> Loops(LI.getLoopsInPreorder());
  SmallVector<StripMinePlan, 4> Plans;
  SmallPtrSet<BasicBlock *, 32> PlannedBlocks;

  bool Versioning = Mode == SafepointStripMiningMode::InclusiveLoopVersioning;
  SmallPtrSet<Loop *, 8> DeferredEmptyLoops;
  if (DeferEmptyLoopDeletion) {
    for (Loop *L : Loops) {
      if (DeferredEmptyLoops.contains(L))
        continue;
      if (!jeandle::isEmptyLoopPollDeletionCandidate(*L, LI, DT, SE))
        continue;
      for (Loop *Nested : L->getLoopsInPreorder())
        DeferredEmptyLoops.insert(Nested);
    }
  }
  for (Loop *L : llvm::reverse(Loops)) {
    if (DeferredEmptyLoops.contains(L)) {
      LLVM_DEBUG(dbgs() << "  strip-mining: skip " << L->getHeader()->getName()
                        << ": empty-loop deletion candidate\n");
      continue;
    }
    auto Plan = buildStripMinePlan(L, LI, DT, SE, MSSA, Versioning);
    if (!Plan)
      continue;
    bool Overlaps = llvm::any_of(L->blocks(), [&](BasicBlock *BB) {
      return PlannedBlocks.contains(BB);
    });
    if (Overlaps)
      continue;
    for (BasicBlock *BB : L->blocks())
      PlannedBlocks.insert(BB);
    Plans.push_back(std::move(*Plan));
  }

  bool Changed = false;
  for (StripMinePlan &Plan : Plans) {
    if (!Plan.stillStructurallyValid(LI, DT))
      continue;
    if (Versioning)
      applyInclusiveLoopVersioningPlan(Plan, LI, DT);
    else
      applyStripMinePlan(Plan, LI, DT, SE);
    Changed = true;
  }
  return Changed ? PreservedAnalyses::none() : PreservedAnalyses::all();
}
