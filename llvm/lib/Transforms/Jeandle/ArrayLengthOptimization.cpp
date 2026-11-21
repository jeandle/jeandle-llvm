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
#include "llvm/ADT/DenseMap.h"
#include "llvm/ADT/STLExtras.h"
#include "llvm/ADT/ScopedHashTable.h"
#include "llvm/ADT/SmallVector.h"
#include "llvm/Analysis/AssumptionCache.h"
#include "llvm/Analysis/LoopInfo.h"
#include "llvm/Analysis/MustExecute.h"
#include "llvm/Analysis/SimplifyQuery.h"
#include "llvm/Analysis/ValueTracking.h"
#include "llvm/IR/CFG.h"
#include "llvm/IR/Dominators.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/Jeandle/JavaType.h"
#include "llvm/IR/Jeandle/Metadata.h"
#include "llvm/IR/Module.h"
#include "llvm/Transforms/Utils/LoopUtils.h"
#include "llvm/Transforms/Utils/SSAUpdater.h"

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
  ScopedHashTable<Value *, Value *> Available;
  DominatorTree &DT;
  LoopInfo &LI;
  unsigned MergeAttempts = 0;

  Value *translateArray(Value *Array, BasicBlock *BB, BasicBlock *Pred) {
    auto *PN = dyn_cast<PHINode>(Array);
    if (!PN || PN->getParent() != BB)
      return Array;
    // A loop-header receiver needs a per-iteration identity proof. Exit PHIs
    // can still be translated when they carry a receiver out of a loop.
    if (LI.isLoopHeader(BB))
      return nullptr;
    return getArrayIdentity(PN->getIncomingValueForBlock(Pred));
  }

  // Certify the complete backward slice before SSAUpdater can insert PHIs.
  // Each block represents one receiver; conflicting translations fail rather
  // than conflating lengths of different arrays in the same SSA variable.
  bool
  collectAvailable(BasicBlock *UseBB, Value *Array,
                   SmallVectorImpl<std::pair<BasicBlock *, Value *>> &Sources) {
    DenseMap<BasicBlock *, Value *> Arrays;
    SmallVector<BasicBlock *, 16> Worklist;
    unsigned Budget = 512;
    auto AddPredecessors = [&](BasicBlock *BB, Value *Receiver) {
      if (pred_empty(BB))
        return false;
      for (BasicBlock *Pred : predecessors(BB)) {
        if (!Budget)
          return false;
        --Budget;
        Value *Incoming = translateArray(Receiver, BB, Pred);
        if (!Incoming || Pred == UseBB || Pred->isEHPad() ||
            !DT.isReachableFromEntry(Pred))
          return false;
        if (auto *I = dyn_cast<Instruction>(Incoming))
          if (!DT.dominates(I, Pred->getTerminator()))
            return false;
        auto It = Arrays.find(Pred);
        if (It != Arrays.end()) {
          if (It->second != Incoming)
            return false;
          continue;
        }
        if (Arrays.size() >= 64)
          return false;
        Arrays[Pred] = Incoming;
        Worklist.push_back(Pred);
      }
      return true;
    };
    if (!AddPredecessors(UseBB, Array))
      return false;
    for (unsigned Idx = 0; Idx != Worklist.size(); ++Idx) {
      BasicBlock *BB = Worklist[Idx];
      Value *Receiver = Arrays.lookup(BB);
      Value *Length = nullptr;
      for (Instruction &I : reverse(*BB)) {
        if (!Budget)
          return false;
        --Budget;
        CallInst *CI = getArrayLength(I);
        if (!CI)
          continue;
        Value *Operand = CI->getArgOperand(0);
        if ((CI->paramHasAttr(0, Attribute::NoUndef) ||
             jeandle::isProvenDefined(Operand)) &&
            getArrayIdentity(Operand) == Receiver) {
          Length = CI;
          break;
        }
      }
      if (Length) {
        Sources.emplace_back(BB, Length);
      } else if (!AddPredecessors(BB, Receiver)) {
        return false;
      }
    }
    // Cycles are allowed only after all their incoming paths are certified.
    // Every visited block is reachable from entry, and an entry without a
    // source fails above, so a cycle cannot support its own initial value.
    return !Sources.empty();
  }

  Value *mergeAvailable(CallInst *CI, Value *Array) {
    if (MergeAttempts++ >= 128)
      return nullptr;
    BasicBlock *BB = CI->getParent();
    if (BB->isEHPad() || pred_empty(BB))
      return nullptr;
    SmallVector<std::pair<BasicBlock *, Value *>, 8> Sources;
    if (!collectAvailable(BB, Array, Sources))
      return nullptr;
    SSAUpdater SSA;
    SSA.Initialize(CI->getType(), "array.length");
    for (auto [SourceBB, Length] : Sources)
      SSA.AddAvailableValue(SourceBB, Length);
    return SSA.GetValueInMiddleOfBlock(BB);
  }

public:
  LengthCSE(DominatorTree &DT, LoopInfo &LI) : DT(DT), LI(LI) {}

  bool visit(DomTreeNode *Node, unsigned Depth = 0) {
    if (Depth == 256)
      return false;
    ScopedHashTableScope<Value *, Value *> Scope(Available);
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
      Value *Earlier = Available.lookup(Array);
      if (!Earlier)
        Earlier = mergeAvailable(CI, Array);
      if (Earlier) {
        Available.insert(Array, Earlier);
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
  Changed |= LengthCSE(DT, LI).visit(DT.getRootNode());
  if (!Changed)
    return PreservedAnalyses::all();
  // Reusing a length can introduce uses across loop boundaries, including
  // through several nested loops. CFG and dominance remain unchanged.
  for (Loop *L : LI)
    formLCSSARecursively(*L, DT, &LI, nullptr);
  PreservedAnalyses PA;
  PA.preserveSet<CFGAnalyses>();
  return PA;
}
