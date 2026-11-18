//===- ArrayLengthOptimization.cpp - Java array lengths
//--------------------===//
//
// Copyright (c) 2026, the Jeandle-LLVM Authors. All Rights Reserved.
//
// Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM
// Exceptions. See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#include "llvm/Transforms/Jeandle/ArrayLengthOptimization.h"
#include "llvm/ADT/STLExtras.h"
#include "llvm/ADT/ScopedHashTable.h"
#include "llvm/Analysis/AssumptionCache.h"
#include "llvm/Analysis/LoopInfo.h"
#include "llvm/Analysis/MustExecute.h"
#include "llvm/Analysis/SimplifyQuery.h"
#include "llvm/Analysis/ValueTracking.h"
#include "llvm/IR/Dominators.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/Jeandle/JavaType.h"
#include "llvm/IR/Jeandle/Metadata.h"
#include "llvm/IR/Module.h"

using namespace llvm;

namespace {

static CallInst *getArrayLength(Instruction &I) {
  auto *CI = dyn_cast<CallInst>(&I);
  if (!CI || CI->arg_size() != 1 || !CI->getType()->isIntegerTy(32) ||
      CI->hasOperandBundles())
    return nullptr;
  Function *Callee = CI->getCalledFunction();
  if (!Callee || Callee->getName() != "jeandle.arraylength" ||
      !CI->getArgOperand(0)->getType()->isPointerTy() ||
      CI->getArgOperand(0)->getType()->getPointerAddressSpace() !=
          jeandle::JavaHeapAddrSpace)
    return nullptr;
  return CI;
}

static Value *getArrayIdentity(Value *V) {
  for (unsigned Depth = 0; Depth != 16; ++Depth) {
    Value *Input = nullptr;
    if (auto *FI = dyn_cast<FreezeInst>(V)) {
      if (jeandle::isProvenDefined(FI->getOperand(0)))
        Input = FI->getOperand(0);
    } else {
      Input = jeandle::getJavaIdentityInput(V);
    }
    if (!Input || Input == V || Input->getType() != V->getType())
      break;
    V = Input;
  }
  return V;
}

// Length belongs to the array's identity, not its mutable element storage.
// Keeping this fact at the JavaOp level avoids overstating the lifetime of
// raw header memory with invariant.load metadata.
class LengthCSE {
  ScopedHashTable<Value *, CallInst *> Available;

public:
  bool visit(DomTreeNode *Node, unsigned Depth = 0) {
    if (Depth == 256)
      return false;
    ScopedHashTableScope<Value *, CallInst *> Scope(Available);
    bool Changed = false;
    for (Instruction &I : make_early_inc_range(*Node->getBlock())) {
      CallInst *CI = getArrayLength(I);
      if (!CI)
        continue;
      Value *Operand = CI->getArgOperand(0);
      // Without noundef each use may choose a different array.
      if (!CI->paramHasAttr(0, Attribute::NoUndef) &&
          !jeandle::isProvenDefined(Operand))
        continue;
      Value *Array = getArrayIdentity(Operand);
      if (CallInst *Earlier = Available.lookup(Array)) {
        CI->replaceAllUsesWith(Earlier);
        CI->eraseFromParent();
        Changed = true;
      } else {
        Available.insert(Array, CI);
      }
    }
    for (DomTreeNode *Child : *Node)
      Changed |= visit(Child, Depth + 1);
    return Changed;
  }
};

} // namespace

PreservedAnalyses ArrayLengthOptimization::run(Function &F,
                                               FunctionAnalysisManager &FAM) {
  if (F.isDeclaration() || !F.getParent()->getNamedMetadata(
                               jeandle::Metadata::JavaMethodCompilation))
    return PreservedAnalyses::all();

  auto &DT = FAM.getResult<DominatorTreeAnalysis>(F);
  auto &LI = FAM.getResult<LoopAnalysis>(F);
  auto &AC = FAM.getResult<AssumptionAnalysis>(F);
  bool Changed = false;
  // Visit inner loops first so a length may subsequently move past an outer
  // loop as well. Neither motion nor CSE changes CFG or array identity.
  SmallVector<Loop *, 8> Loops = LI.getLoopsInPreorder();
  for (Loop *L : reverse(Loops)) {
    BasicBlock *Preheader = L->getLoopPreheader();
    if (!Preheader)
      continue;
    ICFLoopSafetyInfo Safety;
    Safety.computeLoopSafetyInfo(L);
    Instruction *InsertPt = Preheader->getTerminator();
    SimplifyQuery Q(F.getDataLayout(), &DT, &AC, InsertPt);
    for (BasicBlock *BB : L->blocks()) {
      for (Instruction &I : make_early_inc_range(*BB)) {
        CallInst *CI = getArrayLength(I);
        if (!CI)
          continue;
        Value *Array = CI->getArgOperand(0);
        if (!L->isLoopInvariant(Array) || !isKnownNonZero(Array, Q) ||
            !isGuaranteedNotToBeUndefOrPoison(Array, &AC, InsertPt, &DT) ||
            !Safety.isGuaranteedToExecute(*CI, &DT, L))
          continue;
        // Must-execute prevents speculative header reads on paths where the
        // operand has not yet been established to denote a live array.
        Safety.removeInstruction(CI);
        CI->moveBefore(InsertPt->getIterator());
        Changed = true;
      }
    }
  }
  Changed |= LengthCSE().visit(DT.getRootNode());
  if (!Changed)
    return PreservedAnalyses::all();
  PreservedAnalyses PA;
  PA.preserveSet<CFGAnalyses>();
  return PA;
}
