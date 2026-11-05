//===- BoxMaterializationLowering.cpp - Lower surviving box JavaOps -------===//
//
// Copyright (c) 2026, the Jeandle-LLVM Authors. All Rights Reserved.
//
// Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM
// Exceptions. See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#include "llvm/Transforms/Jeandle/BoxMaterializationLowering.h"
#include <optional>
#include "llvm/ADT/SetVector.h"
#include "llvm/ADT/SmallPtrSet.h"
#include "llvm/Analysis/AliasAnalysis.h"
#include "llvm/Analysis/InlineAdvisor.h"
#include "llvm/Analysis/ProfileSummaryInfo.h"
#include "llvm/IR/Constants.h"
#include "llvm/IR/InstIterator.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/Jeandle/Metadata.h"
#include "llvm/IR/MDBuilder.h"
#include "llvm/IR/Module.h"
#include "llvm/Support/Debug.h"
#include "llvm/Transforms/Jeandle/JeandleTransformUtils.h"
#include "llvm/Transforms/Utils/Cloning.h"

using namespace llvm;

#define DEBUG_TYPE "box-materialization-lowering"

namespace {

struct CacheBranchWeights {
  uint32_t Hit;
  uint32_t Miss;
  bool SpeculateCacheHit;
};

static std::optional<CacheBranchWeights>
getCacheBranchWeights(const CallBase &CB) {
  MDNode *MD =
      CB.getMetadata(jeandle::Metadata::BoxCacheBranchWeights);
  if (!MD || MD->getNumOperands() != 3)
    return std::nullopt;

  auto *Hit = mdconst::dyn_extract<ConstantInt>(MD->getOperand(0));
  auto *Miss = mdconst::dyn_extract<ConstantInt>(MD->getOperand(1));
  auto *Speculate = mdconst::dyn_extract<ConstantInt>(MD->getOperand(2));
  if (!Hit || !Miss || Hit->getValue().getActiveBits() > 32 ||
      Miss->getValue().getActiveBits() > 32 || !Speculate ||
      !Speculate->getType()->isIntegerTy(1))
    return std::nullopt;
  return CacheBranchWeights{static_cast<uint32_t>(Hit->getZExtValue()),
                            static_cast<uint32_t>(Miss->getZExtValue()),
                            !Speculate->isZero()};
}

static bool callsNewInstance(const BasicBlock &BB) {
  for (const Instruction &I : BB) {
    auto *CB = dyn_cast<CallBase>(&I);
    if (!CB)
      continue;
    auto *Callee = dyn_cast<Function>(
        CB->getCalledOperand()->stripPointerCasts());
    if (Callee && Callee->getName() == "jeandle.new_instance")
      return true;
  }
  return false;
}

static bool lowerCacheBranch(
    Function &Caller, const SmallPtrSetImpl<BranchInst *> &OldBranches,
    CacheBranchWeights Weights, BasicBlock *Deopt) {
  bool UsedDeopt = false;
  for (BasicBlock &BB : Caller) {
    auto *BI = dyn_cast<BranchInst>(BB.getTerminator());
    if (!BI || OldBranches.contains(BI) || !BI->isConditional())
      continue;
    auto *Cmp = dyn_cast<ICmpInst>(BI->getCondition());
    if (!Cmp || Cmp->getPredicate() != ICmpInst::ICMP_ULT)
      continue;
    // The complete box template emits its cache test as
    //   icmp ult index, cache_length
    // with the false successor owning the real allocation. Recognizing both
    // facts avoids depending on LLVM value/block names, which product builds
    // are allowed to discard.
    if (!callsNewInstance(*BI->getSuccessor(1)))
      continue;
    BI->setMetadata(LLVMContext::MD_prof,
                    MDBuilder(Caller.getContext())
                        .createBranchWeights(Weights.Hit, Weights.Miss));
    if (!Weights.SpeculateCacheHit || !Deopt)
      continue;

    BI->setSuccessor(1, Deopt);
    UsedDeopt = true;
  }
  return UsedDeopt;
}

} // namespace

PreservedAnalyses
BoxMaterializationLowering::run(Module &M, ModuleAnalysisManager &MAM) {
  Function *Box = M.getFunction("jeandle.box");
  if (!Box || Box->isDeclaration() || Box->user_empty())
    return PreservedAnalyses::all();

  FunctionAnalysisManager &FAM =
      MAM.getResult<FunctionAnalysisManagerModuleProxy>(M).getManager();
  auto GetAssumptionCache = [&](Function &F) -> AssumptionCache & {
    return FAM.getResult<AssumptionAnalysis>(F);
  };
  auto &PSI = MAM.getResult<ProfileSummaryAnalysis>(M);
  AAResults &CalleeAA = FAM.getResult<AAManager>(*Box);

  SmallSetVector<CallBase *, 16> Calls;
  for (User *U : Box->users()) {
    auto *CB = dyn_cast<CallBase>(U);
    if (CB && CB->getCalledFunction() == Box)
      Calls.insert(CB);
  }

  bool Changed = false;
  for (CallBase *CB : Calls) {
    Function *Caller = CB->getCaller();
    std::optional<CacheBranchWeights> Weights =
        getCacheBranchWeights(*CB);
    CallInst *DeoptInputsAnchor = nullptr;
    if (Weights && Weights->SpeculateCacheHit) {
      if (auto Bundle = CB->getOperandBundle(LLVMContext::OB_deopt)) {
        // InlineFunction erases the semantic box and may recursively delete
        // instructions used only by its deopt bundle. Keep the inputs as real
        // SSA uses, and read them back afterwards so RAUW performed by the
        // inliner is observed as well. A raw OperandBundleDef would retain
        // dangling Value pointers in either case.
        SmallVector<Value *> Inputs;
        for (const Use &U : Bundle->Inputs)
          Inputs.push_back(U.get());
        IRBuilder<> Builder(CB);
        DeoptInputsAnchor =
            Builder.CreateIntrinsic(Intrinsic::fake_use, Inputs);
      } else {
        Weights->SpeculateCacheHit = false;
      }
    }
    SmallPtrSet<BranchInst *, 16> OldBranches;
    for (BasicBlock &BB : *Caller)
      if (auto *BI = dyn_cast<BranchInst>(BB.getTerminator()))
        OldBranches.insert(BI);

    InlineFunctionInfo IFI(GetAssumptionCache, &PSI, nullptr, nullptr);
    InlineResult Result = InlineFunction(*CB, IFI, /*MergeAttributes=*/true,
                                         &CalleeAA,
                                         /*InsertLifetime=*/true);
    if (!Result.isSuccess()) {
      if (DeoptInputsAnchor)
        DeoptInputsAnchor->eraseFromParent();
      LLVM_DEBUG(dbgs() << "failed to materialize box in "
                        << Caller->getName() << ": " << Result.getFailureReason()
                        << '\n');
      continue;
    }

    BasicBlock *Deopt = nullptr;
    if (DeoptInputsAnchor) {
      SmallVector<Value *> Inputs(DeoptInputsAnchor->args());
      Deopt = BasicBlock::Create(Caller->getContext(),
                                 "box.cache_miss.unstable_if", Caller);
      IRBuilder<> Builder(Deopt);
      buildDeoptimize(Builder, M,
                      jeandle::Deoptimization::Reason_unstable_if,
                      jeandle::Deoptimization::Action_make_not_entrant,
                      OperandBundleDef("deopt", Inputs));
      DeoptInputsAnchor->eraseFromParent();
    }

    if (Weights) {
      bool UsedDeopt = lowerCacheBranch(*Caller, OldBranches, *Weights, Deopt);
      if (Deopt && !UsedDeopt)
        Deopt->eraseFromParent();
    }
    FAM.invalidate(*Caller, PreservedAnalyses::none());
    Changed = true;
  }

  // Once every semantic box has been expanded, the template is dead. Leaving
  // it in the module would send a non-Java helper through later function
  // passes that assume Java-method metadata is present. Clear cached analyses
  // before deleting the function from underneath the FAM.
  if (Box->user_empty()) {
    FAM.clear(*Box, Box->getName());
    Box->eraseFromParent();
    Changed = true;
  }

  if (!Changed)
    return PreservedAnalyses::all();

  PreservedAnalyses PA;
  PA.preserve<FunctionAnalysisManagerModuleProxy>();
  PA.preserveSet<AllAnalysesOn<Function>>();
  return PA;
}

