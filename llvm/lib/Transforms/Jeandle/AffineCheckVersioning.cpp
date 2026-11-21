//===- AffineCheckVersioning.cpp - Affine checks --------------------------===//
//
// Copyright (c) 2026, the Jeandle-LLVM Authors. All Rights Reserved.
//
// Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM
// Exceptions. See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#include "llvm/Transforms/Jeandle/AffineCheckVersioning.h"
#include "llvm/ADT/SmallPtrSet.h"
#include "llvm/Analysis/AssumptionCache.h"
#include "llvm/Analysis/LoopInfo.h"
#include "llvm/Analysis/ScalarEvolution.h"
#include "llvm/Analysis/ScalarEvolutionExpressions.h"
#include "llvm/Analysis/SimplifyQuery.h"
#include "llvm/Analysis/ValueTracking.h"
#include "llvm/IR/CFG.h"
#include "llvm/IR/Dominators.h"
#include "llvm/IR/IRBuilder.h"
#include "llvm/IR/Jeandle/JavaType.h"
#include "llvm/IR/Jeandle/Metadata.h"
#include "llvm/IR/Module.h"
#include "llvm/IR/PatternMatch.h"
#include "llvm/Support/CommandLine.h"
#include "llvm/Support/KnownBits.h"
#include "llvm/Transforms/Jeandle/SafepointUtils.h"
#include "llvm/Transforms/Utils/BasicBlockUtils.h"
#include "llvm/Transforms/Utils/Cloning.h"
#include "llvm/Transforms/Utils/LoopUtils.h"
#include "llvm/Transforms/Utils/ScalarEvolutionExpander.h"

using namespace llvm;
using namespace llvm::PatternMatch;

static cl::opt<bool> EnableAffineVersioning(
    "jeandle-affine-check-versioning", cl::init(true), cl::Hidden,
    cl::desc("Version affine array checks left by standard loop transforms"));

static cl::opt<unsigned> MinVersionedTripCount(
    "jeandle-affine-min-trip-count", cl::init(10), cl::Hidden,
    cl::desc("Minimum estimated loop trips for affine check versioning"));

namespace {

constexpr const char *VersionedMD = "llvm.loop.jeandle.check.versioned";

struct RangeCheck {
  ICmpInst *Condition;
  const SCEV *Start;
  const SCEV *Step;
  Value *Length;
  bool SuccessOnTrue;
};

struct CheckCondition {
  BranchInst *Branch;
  SmallVector<Instruction *, 8> Nodes;
};

struct ExitIncoming {
  PHINode *Phi;
  Value *V;
  BasicBlock *From;
};

struct VersionPlan {
  Loop *L;
  Value *Init;
  Value *Limit;
  APInt Step;
  ICmpInst::Predicate Predicate;
  SmallVector<RangeCheck, 4> Checks;
  SmallVector<CheckCondition, 4> Conditions;
  SmallVector<ExitIncoming, 8> Exits;
};

// Expansion must not turn a conditional or undefined input into an eager
// guard operand. Restrict the start to bounded, pure modular arithmetic on
// values already defined at the preheader.
bool isDefinedAt(Value *V, Instruction *At, AssumptionCache &AC,
                 DominatorTree &DT) {
  if (isGuaranteedNotToBeUndefOrPoison(V, &AC, At, &DT))
    return true;
  // ValueTracking conservatively rejects nneg extensions as poison producers.
  // A dominating Java loop-entry test can establish their non-negative input.
  auto *Ext = dyn_cast<ZExtInst>(V);
  if (!Ext || !Ext->hasNonNeg() ||
      !isGuaranteedNotToBeUndefOrPoison(Ext->getOperand(0), &AC, At, &DT))
    return false;
  SimplifyQuery Q(At->getModule()->getDataLayout(), &DT, &AC, Ext);
  return isKnownNonNegative(Ext->getOperand(0), Q) ||
         isImpliedByDomCondition(ICmpInst::ICMP_SGE, Ext->getOperand(0),
                                 ConstantInt::get(Ext->getSrcTy(), 0), Ext,
                                 At->getModule()->getDataLayout()) == true;
}

bool isDefinedStart(const SCEV *S, Loop *L, Instruction *At,
                    AssumptionCache &AC, DominatorTree &DT) {
  SmallVector<const SCEV *, 8> Work{S};
  SmallPtrSet<const SCEV *, 16> Seen;
  while (!Work.empty()) {
    S = Work.pop_back_val();
    if (!Seen.insert(S).second)
      continue;
    if (Seen.size() > 64)
      return false;
    if (isa<SCEVConstant>(S))
      continue;
    if (auto *U = dyn_cast<SCEVUnknown>(S)) {
      Value *V = U->getValue();
      if (!L->isLoopInvariant(V) || !isDefinedAt(V, At, AC, DT))
        return false;
    } else if (auto *C = dyn_cast<SCEVCastExpr>(S)) {
      Work.push_back(C->getOperand());
    } else if (isa<SCEVAddExpr, SCEVMulExpr>(S)) {
      append_range(Work, cast<SCEVNAryExpr>(S)->operands());
    } else {
      return false;
    }
  }
  return true;
}

Value *getLength(Value *V, Loop *L, DominatorTree &DT, AssumptionCache &AC,
                 Instruction *At) {
  // Widened compares can keep their extension inside the loop even when the
  // Java length itself is invariant. A nonnegative source has the same value
  // under either extension, including nneg zext.
  if (auto *Ext = dyn_cast<CastInst>(V))
    if (Ext->getOpcode() == Instruction::ZExt ||
        Ext->getOpcode() == Instruction::SExt)
      V = Ext->getOperand(0);
  if (!V->getType()->isIntegerTy() || V->getType()->getIntegerBitWidth() > 64 ||
      !L->isLoopInvariant(V) || !isDefinedAt(V, At, AC, DT))
    return nullptr;
  if (auto *I = dyn_cast<Instruction>(V))
    if (!DT.dominates(I, At))
      return nullptr;
  SimplifyQuery Q(At->getModule()->getDataLayout(), &DT, &AC, At);
  if (!isKnownNonNegative(V, Q))
    return nullptr;
  // Java array lengths fit in a nonnegative int. This also keeps the
  // mathematical index endpoints within the signed range of their IR type.
  if (V->getType()->getIntegerBitWidth() > 32 &&
      computeKnownBits(V, Q).countMaxActiveBits() > 31)
    return nullptr;
  return V;
}

void collectRangeCheck(ICmpInst *Cmp, bool Success, Loop *L,
                       ScalarEvolution &SE, DominatorTree &DT,
                       AssumptionCache &AC, SCEVExpander &Expander,
                       SmallVectorImpl<RangeCheck> &Checks) {
  if (!Cmp->getOperand(0)->getType()->isIntegerTy() ||
      Cmp->getOperand(0)->getType()->getIntegerBitWidth() > 64)
    return;
  Instruction *At = L->getLoopPreheader()->getTerminator();
  Value *Index = Cmp->getOperand(0);
  Value *Length = getLength(Cmp->getOperand(1), L, DT, AC, At);
  auto Pred = Cmp->getPredicate();
  if (!Length) {
    Index = Cmp->getOperand(1);
    Length = getLength(Cmp->getOperand(0), L, DT, AC, At);
    Pred = ICmpInst::getSwappedPredicate(Pred);
  }
  if (!Success)
    Pred = ICmpInst::getInversePredicate(Pred);
  if (!Length || (Pred != ICmpInst::ICMP_ULT && Pred != ICmpInst::ICMP_SLT))
    return;

  // InstCombine folds (x < 2^k) && (y < 2^k) into (x | y) < 2^k.
  // Every operand must satisfy the endpoint proof before replacing this leaf.
  auto *Bound = dyn_cast<ConstantInt>(Length);
  bool SplitOr = Bound && Bound->getValue().isPowerOf2();
  SmallVector<Value *, 8> Indices{Index};
  SmallVector<RangeCheck, 4> Ranges;
  unsigned Nodes = 0;
  while (!Indices.empty()) {
    Value *V = Indices.pop_back_val();
    if (++Nodes > 16)
      return;
    Value *X, *Y;
    if (SplitOr && match(V, m_Or(m_Value(X), m_Value(Y)))) {
      Indices.push_back(X);
      Indices.push_back(Y);
      continue;
    }
    const auto *AR = dyn_cast<SCEVAddRecExpr>(SE.getSCEV(V));
    if (!AR || AR->getLoop() != L || !AR->isAffine())
      return;
    const SCEV *Step = AR->getStepRecurrence(SE);
    if (!isDefinedStart(AR->getStart(), L, At, AC, DT) ||
        !isDefinedStart(Step, L, At, AC, DT) ||
        !Expander.isSafeToExpandAt(AR->getStart(), At) ||
        !Expander.isSafeToExpandAt(Step, At))
      return;
    Ranges.push_back({Cmp, AR->getStart(), Step, Length, Success});
  }
  // Bound both entry work and the number of conditions removed per version.
  if (Checks.size() + Ranges.size() <= 8)
    append_range(Checks, Ranges);
}

void collectCondition(Value *V, bool Success, Loop *L, ScalarEvolution &SE,
                      DominatorTree &DT, AssumptionCache &AC,
                      SCEVExpander &Expander, VersionPlan &Plan,
                      CheckCondition &Condition,
                      SmallPtrSetImpl<Value *> &Seen) {
  if (Seen.size() == 64 || !Seen.insert(V).second)
    return;
  Value *X, *Y;
  if ((Success && match(V, m_LogicalAnd(m_Value(X), m_Value(Y)))) ||
      (!Success && match(V, m_LogicalOr(m_Value(X), m_Value(Y))))) {
    collectCondition(X, Success, L, SE, DT, AC, Expander, Plan, Condition,
                     Seen);
    collectCondition(Y, Success, L, SE, DT, AC, Expander, Plan, Condition,
                     Seen);
    Condition.Nodes.push_back(cast<Instruction>(V));
  } else if (match(V, m_Not(m_Value(X)))) {
    collectCondition(X, !Success, L, SE, DT, AC, Expander, Plan, Condition,
                     Seen);
    Condition.Nodes.push_back(cast<Instruction>(V));
  } else if (auto *Cmp = dyn_cast<ICmpInst>(V)) {
    collectRangeCheck(Cmp, Success, L, SE, DT, AC, Expander, Plan.Checks);
  }
}

std::optional<VersionPlan> planVersion(Loop *L, ScalarEvolution &SE,
                                       DominatorTree &DT, AssumptionCache &AC) {
  if (!L->isInnermost() || !L->isLoopSimplifyForm() || !L->isLCSSAForm(DT) ||
      findOptionMDForLoop(L, VersionedMD))
    return std::nullopt;
  // LoopConstrainer marks its checked pre/post clones on the latch. Leave
  // those deliberately small residual ranges alone; other loops may still
  // need versioning even when their index and controller have equal steps.
  if (L->getLoopLatch()->getTerminator()->getMetadata(
          "loop_constrainer.loop.clone"))
    return std::nullopt;
  // Like IRCE, avoid paying for entry predicates and a cloned fallback when
  // profile already predicts too few iterations to amortize that work.
  if (auto Trips = getLoopEstimatedTripCount(L))
    if (*Trips < MinVersionedTripCount)
      return std::nullopt;
  unsigned Size = 0;
  for (BasicBlock *BB : L->blocks()) {
    if (BB->isEHPad() || BB->hasAddressTaken())
      return std::nullopt;
    for (Instruction &I : *BB) {
      if (++Size > 200 || isa<IndirectBrInst, CallBrInst>(I) ||
          I.getType()->isTokenTy())
        return std::nullopt;
      if (auto *CB = dyn_cast<CallBase>(&I))
        if (CB->cannotDuplicate() || CB->isConvergent())
          return std::nullopt;
    }
  }
  auto Bounds = L->getBounds(SE);
  PHINode *IV = L->getInductionVariable(SE);
  if (!Bounds || !IV || !IV->getType()->isIntegerTy() ||
      IV->getType()->getIntegerBitWidth() > 64)
    return std::nullopt;
  auto Step = jeandle::getConstantAddStep(&Bounds->getStepInst(), IV);
  if (!Step || Step->isZero())
    return std::nullopt;
  auto *Br = dyn_cast<BranchInst>(L->getLoopLatch()->getTerminator());
  auto *Cmp = Br && Br->isConditional() ? dyn_cast<ICmpInst>(Br->getCondition())
                                        : nullptr;
  if (!Cmp || (Br->getSuccessor(0) != L->getHeader() &&
               Br->getSuccessor(1) != L->getHeader()))
    return std::nullopt;
  unsigned Backedge = Br->getSuccessor(0) == L->getHeader() ? 0 : 1;
  if (Br->getSuccessor(1 - Backedge)->getTerminatingDeoptimizeCall())
    return std::nullopt;
  Value *Init = &Bounds->getInitialIVValue();
  Value *Limit = &Bounds->getFinalIVValue();
  auto Pred = Cmp->getPredicate();
  if (Cmp->getOperand(0) == Limit &&
      Cmp->getOperand(1) == &Bounds->getStepInst())
    Pred = ICmpInst::getSwappedPredicate(Pred);
  else if (Cmp->getOperand(0) != &Bounds->getStepInst() ||
           Cmp->getOperand(1) != Limit)
    return std::nullopt;
  if (Backedge == 1)
    Pred = ICmpInst::getInversePredicate(Pred);
  bool Increasing = !Step->isNegative();
  if (Pred != ICmpInst::ICMP_NE &&
      (Increasing
           ? Pred != ICmpInst::ICMP_SLT && Pred != ICmpInst::ICMP_SLE &&
                 Pred != ICmpInst::ICMP_ULT && Pred != ICmpInst::ICMP_ULE
           : Pred != ICmpInst::ICMP_SGT && Pred != ICmpInst::ICMP_SGE &&
                 Pred != ICmpInst::ICMP_UGT && Pred != ICmpInst::ICMP_UGE))
    return std::nullopt;
  Instruction *At = L->getLoopPreheader()->getTerminator();
  if (!isa<BranchInst>(At) || !L->isLoopInvariant(Init) ||
      !L->isLoopInvariant(Limit) || Init->getType() != Limit->getType() ||
      !isDefinedAt(Init, At, AC, DT) || !isDefinedAt(Limit, At, AC, DT))
    return std::nullopt;
  VersionPlan Plan{L, Init, Limit, *Step, Pred, {}, {}, {}};
  SCEVExpander Expander(SE, "affine");
  for (BasicBlock *BB : L->blocks()) {
    auto *Check = dyn_cast<BranchInst>(BB->getTerminator());
    if (!Check || !Check->isConditional() || Check == Br)
      continue;
    bool Success = L->contains(Check->getSuccessor(0));
    if (Success == L->contains(Check->getSuccessor(1)))
      continue;
    BasicBlock *Exit = Check->getSuccessor(Success ? 1 : 0);
    if (Exit->isEHPad() || Exit->hasAddressTaken())
      continue;
    CheckCondition Condition{Check, {}};
    SmallPtrSet<Value *, 32> Seen;
    size_t Before = Plan.Checks.size();
    collectCondition(Check->getCondition(), Success, L, SE, DT, AC, Expander,
                     Plan, Condition, Seen);
    if (Plan.Checks.size() != Before)
      Plan.Conditions.push_back(std::move(Condition));
  }
  if (Plan.Checks.empty())
    return std::nullopt;
  SmallVector<BasicBlock *, 8> Exits;
  L->getUniqueExitBlocks(Exits);
  for (BasicBlock *Exit : Exits)
    for (PHINode &Phi : Exit->phis())
      for (unsigned I = 0; I < Phi.getNumIncomingValues(); ++I)
        if (L->contains(Phi.getIncomingBlock(I)))
          Plan.Exits.push_back(
              {&Phi, Phi.getIncomingValue(I), Phi.getIncomingBlock(I)});
  return Plan;
}

void applyVersion(VersionPlan &Plan, ScalarEvolution &SE, DominatorTree &DT,
                  LoopInfo &LI) {
  Loop *L = Plan.L;
  BasicBlock *CheckBB = L->getLoopPreheader();
  CheckBB->setName(L->getHeader()->getName() + ".affine.check");
  Instruction *At = CheckBB->getTerminator();
  unsigned Bits = Plan.Step.getBitWidth();
  for (const RangeCheck &Check : Plan.Checks)
    Bits = std::max(Bits, Check.Step->getType()->getIntegerBitWidth());
  IntegerType *Wide = IntegerType::get(At->getContext(), Bits * 2);
  IRBuilder<> B(At);
  bool Signed = !ICmpInst::isUnsigned(Plan.Predicate);
  bool Increasing = !Plan.Step.isNegative();
  Value *Init = B.CreateIntCast(Plan.Init, Wide, Signed, "affine.init");
  Value *Limit = B.CreateIntCast(Plan.Limit, Wide, Signed, "affine.limit");
  Value *Distance =
      Increasing ? B.CreateSub(Limit, Init) : B.CreateSub(Init, Limit);
  APInt Step = Plan.Step.sext(Wide->getBitWidth());
  APInt AbsStep = Increasing ? Step : -Step;
  Value *Stride = ConstantInt::get(Wide, AbsStep);
  Value *Nonnegative = B.CreateSelect(
      B.CreateICmpSGT(Distance, B.getIntN(Wide->getBitWidth(), 0)), Distance,
      ConstantInt::get(Wide, 0));
  Value *Guard = B.getTrue();
  Value *Trips = nullptr;
  if (Plan.Predicate == ICmpInst::ICMP_NE) {
    Guard = B.CreateAnd(B.CreateICmpSGT(Distance, ConstantInt::get(Wide, 0)),
                        B.CreateICmpEQ(B.CreateURem(Nonnegative, Stride),
                                       ConstantInt::get(Wide, 0)));
    Trips = B.CreateUDiv(Nonnegative, Stride);
  } else {
    bool Inclusive = Plan.Predicate == ICmpInst::ICMP_SLE ||
                     Plan.Predicate == ICmpInst::ICMP_SGE ||
                     Plan.Predicate == ICmpInst::ICMP_ULE ||
                     Plan.Predicate == ICmpInst::ICMP_UGE;
    Value *Numerator =
        Inclusive
            ? Nonnegative
            : B.CreateAdd(Nonnegative, ConstantInt::get(Wide, AbsStep - 1));
    Trips = B.CreateUDiv(Numerator, Stride);
    if (Inclusive)
      Trips = B.CreateAdd(Trips, ConstantInt::get(Wide, 1));
    // Rotated loops execute at least one iteration even if their initial
    // value already lies beyond the latch limit.
    Trips = B.CreateSelect(B.CreateICmpEQ(Trips, ConstantInt::get(Wide, 0)),
                           ConstantInt::get(Wide, 1), Trips);
  }
  Value *Next = B.CreateAdd(
      Init, B.CreateMul(Trips, ConstantInt::get(Wide, Step)), "affine.next");
  unsigned IVBits = Plan.Step.getBitWidth();
  APInt Min = Signed
                  ? APInt::getSignedMinValue(IVBits).sext(Wide->getBitWidth())
                  : APInt(Wide->getBitWidth(), 0);
  APInt Max = Signed
                  ? APInt::getSignedMaxValue(IVBits).sext(Wide->getBitWidth())
                  : APInt::getMaxValue(IVBits).zext(Wide->getBitWidth());
  Guard = B.CreateAnd(
      Guard,
      B.CreateAnd(B.CreateICmpSGE(Next, ConstantInt::get(Wide, Min)),
                  B.CreateICmpSLE(Next, ConstantInt::get(Wide, Max))),
      "affine.no_wrap");
  Value *LastIteration = B.CreateSub(Trips, ConstantInt::get(Wide, 1));
  SCEVExpander Expander(SE, "affine.start");
  for (const RangeCheck &Check : Plan.Checks) {
    Value *First =
        Expander.expandCodeFor(Check.Start, Check.Start->getType(), At);
    First = B.CreateSExt(First, Wide, "affine.first");
    Value *IndexStep =
        Expander.expandCodeFor(Check.Step, Check.Step->getType(), At);
    IndexStep = B.CreateSExt(IndexStep, Wide, "affine.step");
    Value *Last = B.CreateAdd(First, B.CreateMul(LastIteration, IndexStep),
                              "affine.last");
    Value *Negative = B.CreateICmpSLT(IndexStep, ConstantInt::get(Wide, 0));
    Value *Low = B.CreateSelect(Negative, Last, First, "affine.low");
    Value *High = B.CreateSelect(Negative, First, Last, "affine.high");
    Value *Length = B.CreateZExt(Check.Length, Wide, "affine.length");
    Value *Safe = B.CreateAnd(B.CreateICmpSGE(Low, ConstantInt::get(Wide, 0)),
                              B.CreateICmpULT(High, Length), "affine.range");
    Guard = B.CreateAnd(Guard, Safe, "affine.safe");
  }
  // No-wrap information inferred from successful checks cannot justify the
  // guard that removes those checks. Expansion uses only modular starts;
  // controller no-wrap and every endpoint are checked independently above.
  for (Instruction *I : Expander.getAllInsertedInstructions())
    I->dropPoisonGeneratingFlags();

  BasicBlock *FastPH = SplitBlock(CheckBB, At, &DT, &LI, nullptr,
                                  L->getHeader()->getName() + ".affine.fast");
  ValueToValueMapTy VMap;
  SmallVector<BasicBlock *, 8> SlowBlocks;
  Loop *Slow = cloneLoopWithPreheader(FastPH, CheckBB, L, VMap, ".affine.slow",
                                      &LI, &DT, SlowBlocks);
  remapInstructionsInBlocks(SlowBlocks, VMap);
  for (const ExitIncoming &Incoming : Plan.Exits) {
    Value *V = Incoming.V;
    if (auto It = VMap.find(V); It != VMap.end())
      V = It->second;
    Incoming.Phi->addIncoming(V, cast<BasicBlock>(VMap[Incoming.From]));
  }
  Instruction *OldTerm = CheckBB->getTerminator();
  IRBuilder<> Entry(OldTerm);
  Entry.CreateCondBr(Guard, FastPH, Slow->getLoopPreheader());
  OldTerm->eraseFromParent();
  for (const CheckCondition &Condition : Plan.Conditions) {
    DenseMap<Value *, Value *> Replacements;
    for (const RangeCheck &Check : Plan.Checks)
      Replacements[Check.Condition] =
          ConstantInt::getBool(At->getContext(), Check.SuccessOnTrue);
    // Rebuild only the branch's boolean expression. Other uses, including
    // shared conditions and deopt operands, keep their original values.
    for (Instruction *I : Condition.Nodes) {
      if (none_of(I->operands(),
                  [&](Value *V) { return Replacements.contains(V); }))
        continue;
      Instruction *Copy = I->clone();
      Copy->setName(I->getName() + ".affine");
      for (Use &U : Copy->operands())
        if (auto It = Replacements.find(U.get()); It != Replacements.end())
          U.set(It->second);
      Copy->insertBefore(Condition.Branch->getIterator());
      Replacements[I] = Copy;
    }
    if (auto It = Replacements.find(Condition.Branch->getCondition());
        It != Replacements.end())
      Condition.Branch->setCondition(It->second);
  }
  addStringMetadataToLoop(L, VersionedMD, 1);
  addStringMetadataToLoop(Slow, VersionedMD, 1);
  DT.recalculate(*L->getHeader()->getParent());
  formDedicatedExitBlocks(L, &DT, &LI, nullptr, true);
  formDedicatedExitBlocks(Slow, &DT, &LI, nullptr, true);
}

} // namespace

PreservedAnalyses AffineCheckVersioning::run(Function &F,
                                             FunctionAnalysisManager &FAM) {
  if (!EnableAffineVersioning || F.isDeclaration() ||
      F.getInstructionCount() > 10000 ||
      !F.getParent()->getNamedMetadata(
          jeandle::Metadata::JavaMethodCompilation))
    return PreservedAnalyses::all();
  bool Changed = false;
  for (unsigned Versions = 0; Versions != 4; ++Versions) {
    auto &LI = FAM.getResult<LoopAnalysis>(F);
    auto &DT = FAM.getResult<DominatorTreeAnalysis>(F);
    auto &SE = FAM.getResult<ScalarEvolutionAnalysis>(F);
    auto &AC = FAM.getResult<AssumptionAnalysis>(F);
    bool Versioned = false;
    SmallVector<Loop *, 8> Loops = LI.getLoopsInPreorder();
    for (Loop *L : reverse(Loops)) {
      auto Plan = planVersion(L, SE, DT, AC);
      if (!Plan)
        continue;
      applyVersion(*Plan, SE, DT, LI);
      // All loop/SCEV/MemorySSA caches must be refreshed before planning a
      // different source loop. No analysis from this iteration is read again.
      FAM.invalidate(F, PreservedAnalyses::none());
      Versioned = Changed = true;
      break;
    }
    if (!Versioned)
      break;
  }
  return Changed ? PreservedAnalyses::none() : PreservedAnalyses::all();
}
