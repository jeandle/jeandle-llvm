//===- InsertGCBarriers.cpp - Insert GC Barriers --------------------------===//
//
// Copyright (c) 2025, the Jeandle-LLVM Authors. All Rights Reserved.
//
// Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM
// Exceptions. See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#include "llvm/Transforms/Jeandle/InsertGCBarriers.h"
#include "llvm/Analysis/LoopInfo.h"
#include "llvm/IR/DerivedTypes.h"
#include "llvm/IR/Dominators.h"
#include "llvm/IR/IRBuilder.h"
#include "llvm/IR/InstIterator.h"
#include "llvm/IR/Instruction.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/Jeandle/Metadata.h"
#include "llvm/IR/Module.h"
#include "llvm/Support/Debug.h"

using namespace llvm;

#define DEBUG_TYPE "insert-gc-barriers"

namespace {

bool isJavaHeapStore(Instruction *I) {
  StoreInst *SI = dyn_cast<StoreInst>(I);
  if (!SI) {
    return false;
  }

  Value *StoredValue = SI->getValueOperand();
  Value *StoreAddress = SI->getPointerOperand();

  if (!StoredValue->getType()->isPointerTy() ||
      !StoreAddress->getType()->isPointerTy()) {
    return false;
  }

  PointerType *StoredValueTy = dyn_cast<PointerType>(StoredValue->getType());
  PointerType *StoreAddressTy = dyn_cast<PointerType>(StoreAddress->getType());

  if (StoredValueTy->getAddressSpace() !=
          jeandle::AddrSpace::JavaHeapAddrSpace ||
      StoreAddressTy->getAddressSpace() !=
          jeandle::AddrSpace::JavaHeapAddrSpace) {
    return false;
  }

  assert(SI->isAtomic() && "store in java heap is expected to be atomic");
  return true;
}

} // end anonymous namespace

PreservedAnalyses InsertGCBarriers::run(Function &F,
                                        FunctionAnalysisManager &FAM) {
  bool Changed = false;

  Module *M = F.getParent();

  // Only java method compilations need gc barriers.
  if (!M->getNamedMetadata(jeandle::Metadata::JavaMethodCompilation)) {
    return PreservedAnalyses::all();
  }

  Function *CardTableBarrierFunc = M->getFunction("jeandle.card_table_barrier");
  assert(CardTableBarrierFunc != nullptr &&
         "jeandle.card_table_barrier must exist");

  LLVM_DEBUG(dbgs() << "Inserting GC barriers in " << F.getName() << "\n");
  SmallVector<StoreInst *> JavaHeapStores;
  for (auto &I : instructions(F)) {
    if (isJavaHeapStore(&I)) {
      JavaHeapStores.push_back(dyn_cast<StoreInst>(&I));
    }
  }

  for (auto SI : JavaHeapStores) {
    IRBuilder<> Builder(SI->getNextNode());

    Value *DerivedPointer = SI->getPointerOperand();
    Type *PointerTy = DerivedPointer->getType();
    Value *BasePointer = Builder.CreateIntrinsic(
        Intrinsic::experimental_gc_get_pointer_base, {PointerTy, PointerTy},
        {DerivedPointer}, {} /* FMFSource */, "base.pointer");
    CallInst *call = Builder.CreateCall(CardTableBarrierFunc, BasePointer);
    call->setCallingConv(CallingConv::Hotspot_JIT);
    Changed = true;
  }

  if (!Changed) {
    return PreservedAnalyses::all();
  }

  PreservedAnalyses PA;
  PA.preserveSet<CFGAnalyses>();
  PA.preserve<LoopAnalysis>();

  return PA;
}
