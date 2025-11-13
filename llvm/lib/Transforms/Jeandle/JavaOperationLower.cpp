//===- JavaOperationLower.cpp - Lower Java Operations ---------------------===//
//
// Copyright (c) 2025, the Jeandle-LLVM Authors. All Rights Reserved.
//
// Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM
// Exceptions. See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#include "llvm/Transforms/Jeandle/JavaOperationLower.h"
#include "llvm/ADT/SetVector.h"
#include "llvm/Analysis/AliasAnalysis.h"
#include "llvm/Analysis/InlineAdvisor.h"
#include "llvm/Analysis/ProfileSummaryInfo.h"
#include "llvm/IR/InstIterator.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/Jeandle/Attributes.h"
#include "llvm/IR/Module.h"
#include "llvm/Transforms/Utils/Cloning.h"
#include "llvm/Transforms/Utils/ModuleUtils.h"

using namespace llvm;

#define DEBUG_TYPE "java-operation-lower"

namespace {

static bool removeFunctionFromLLVMUsed(Module &M, Function &F) {
  GlobalVariable *UsedArray = M.getGlobalVariable("llvm.used");
  if (!UsedArray)
    return false;

  ConstantArray *InitArray = cast<ConstantArray>(UsedArray->getInitializer());
  if (!InitArray) {
    UsedArray->eraseFromParent();
    return false;
  }

  std::vector<Constant *> NewElements;
  bool found = false;

  // Find all elements to be preserved.
  for (unsigned i = 0; i < InitArray->getNumOperands(); i++) {
    Constant *Element = InitArray->getOperand(i);
    if (Function *Func = dyn_cast<Function>(Element)) {
      if (Func == &F) {
        found = true;
        continue;
      }
    }
    NewElements.push_back(Element);
  }

  if (!found)
    return false;

  UsedArray->eraseFromParent();

  // Erase the empty llvm.used directly.
  if (NewElements.empty())
    return true;

  // Create a new llvm.used with the preserved elements.
  auto *NewArrayTy = ArrayType::get(InitArray->getType()->getElementType(),
                                    NewElements.size());

  auto *NewUsedArray = new GlobalVariable(
      M, NewArrayTy, false, GlobalValue::AppendingLinkage,
      ConstantArray::get(NewArrayTy, NewElements), "llvm.used");
  NewUsedArray->setSection("llvm.metadata");

  return true;
}

static bool
runImpl(Module &M, int Phase, FunctionAnalysisManager *FAM,
        function_ref<AAResults &(Function &)> GetAAR, ProfileSummaryInfo &PSI,
        function_ref<AssumptionCache &(Function &)> GetAssumptionCache) {
  bool Changed = false;
  SmallSetVector<CallBase *, 16> Calls;

  auto shouldInline = [Phase](const Function &F) -> bool {
    if (!F.hasFnAttribute(jeandle::Attribute::LowerPhase))
      return false;
    int V = 0;
    bool Failed = F.getFnAttribute(jeandle::Attribute::LowerPhase)
                      .getValueAsString()
                      .getAsInteger(10, V);
    assert(!Failed && "wrong value of LowerPhase attribute");
    return V == Phase;
  };

  for (Function &F : make_early_inc_range(M)) {
    if (!shouldInline(F))
      continue;

    assert(!F.isPresplitCoroutine() &&
           "A presplit coroutine function should not be a JavaOp");
    assert(!F.isDeclaration() &&
           "A function declaration should not be a JavaOp");
    assert(isInlineViable(F).isSuccess() &&
           "Function should be viable for inlining");

    if (removeFunctionFromLLVMUsed(M, F)) {
      LLVM_DEBUG(dbgs() << "remove function:" << F.getName() << "from llvm.used"
                        << " in lower phase: " << Phase << "\n");
    }

    Calls.clear();
    for (User *U : F.users())
      if (auto *CB = dyn_cast<CallBase>(U)) {
        if (CB->getCalledFunction() == &F)
          Calls.insert(CB);
      }

    for (CallBase *CB : Calls) {
      Function *Caller = CB->getCaller();
      InlineFunctionInfo IFI(GetAssumptionCache, &PSI, nullptr, nullptr);
      InlineResult Res = InlineFunction(*CB, IFI, /*MergeAttributes=*/true,
                                        &GetAAR(F), /*InsertLifetime=*/true);
      if (!Res.isSuccess()) {
        LLVM_DEBUG(dbgs() << "failed to inline: " << Caller->getName()
                          << " in lower phase: " << Phase << "\n");
        continue;
      }

      if (FAM)
        FAM->invalidate(*Caller, PreservedAnalyses::none());
    }

    F.removeDeadConstantUsers();

    assert(F.user_empty() && "JavaOp should not be used after lowering");

    if (FAM)
      FAM->clear(F, F.getName());
    M.getFunctionList().erase(F);

    LLVM_DEBUG(dbgs() << "remove lowered JavaOp: " << F.getName()
                      << " in lower phase: " << Phase << "\n");

    Changed = true;
  }
  return Changed;
}

} // end anonymous namespace

namespace llvm {

PreservedAnalyses JavaOperationLower::run(Module &M,
                                          ModuleAnalysisManager &MAM) {
  FunctionAnalysisManager &FAM =
      MAM.getResult<FunctionAnalysisManagerModuleProxy>(M).getManager();
  auto GetAAR = [&](Function &F) -> AAResults & {
    return FAM.getResult<AAManager>(F);
  };
  auto GetAssumptionCache = [&](Function &F) -> AssumptionCache & {
    return FAM.getResult<AssumptionAnalysis>(F);
  };
  auto &PSI = MAM.getResult<ProfileSummaryAnalysis>(M);

  if (!runImpl(M, Phase, &FAM, GetAAR, PSI, GetAssumptionCache))
    return PreservedAnalyses::all();

  PreservedAnalyses PA;
  // We have already invalidated all analyses on modified functions.
  PA.preserveSet<AllAnalysesOn<Function>>();
  return PA;
}

} // end namespace llvm
