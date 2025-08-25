//===- TLSPointerRewrite.cpp - Add a TLS base for TLS pointers ------------===//
//
// Copyright (c) 2025, the Jeandle-LLVM Authors. All Rights Reserved.
//
// Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM
// Exceptions. See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#include "llvm/Transforms/Jeandle/TLSPointerRewrite.h"
#include "llvm/ADT/SmallSet.h"
#include "llvm/IR/Function.h"
#include "llvm/IR/IRBuilder.h"
#include "llvm/IR/InstIterator.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/Jeandle/Metadata.h"
#include "llvm/IR/Module.h"
#include "llvm/Support/Debug.h"

using namespace llvm;

#define DEBUG_TYPE "tls-pointer-rewrite"

// Add a TLS base for TLS pointers.
// TLS pointers are not allowed for global values, return values and arguments.
PreservedAnalyses TLSPointerRewrite::run(Function &F,
                                         FunctionAnalysisManager &) {
  LLVM_DEBUG(dbgs() << "Looking up TLS pointers in " << F.getName() << "\n");

  SmallSet<Value *, 16> ValuesToRewrite;

  auto NeedRewrite = [&](Value *Val) {
    if (dyn_cast<PHINode>(Val)) {
      // Never rewrite phi nodes.
      return false;
    }

    PointerType *ValueType = dyn_cast<PointerType>(Val->getType());
    if (ValueType &&
        ValueType->getAddressSpace() == jeandle::AddrSpace::TLSAddrSpace) {
      assert((dyn_cast<Constant>(Val) ||
              (dyn_cast<Instruction>(Val) && !dyn_cast<ReturnInst>(Val) &&
               !dyn_cast<CallInst>(Val))) &&
             !dyn_cast<GlobalVariable>(Val) && !dyn_cast<Argument>(Val) &&
             "invalid TLS pointer");
      return true;
    }
    return false;
  };

  for (Instruction &I : instructions(F)) {
    // Check all operands.
    for (Value *Op : I.operands()) {
      if (NeedRewrite(Op)) {
        ValuesToRewrite.insert(Op);
      }
    }

    // Check this instruction.
    if (NeedRewrite(&I)) {
      ValuesToRewrite.insert(&I);
    }
  }

  if (ValuesToRewrite.empty()) {
    return PreservedAnalyses::all();
  }

  IRBuilder<> Builder(F.getContext());
  Module *M = F.getParent();
  Type *IntptrType = Builder.getIntPtrTy(M->getDataLayout());

  // Initialize TLSBase.
  Builder.SetInsertPoint(&*inst_begin(F));
  NamedMDNode *ThreadRegister =
      M->getNamedMetadata(jeandle::Metadata::CurrentThread);
  assert(ThreadRegister != nullptr && "current_thread metadata must exist");
  Value *ReadRegsArgs[] = {
      MetadataAsValue::get(F.getContext(), ThreadRegister->getOperand(0))};
  Instruction *TLSBase = Builder.CreateIntrinsic(Intrinsic::read_register,
                                                 IntptrType, ReadRegsArgs);

  for (Value *Val : ValuesToRewrite) {
    LLVM_DEBUG(dbgs() << "Rewriting TLS pointer: " << *Val << "\n");

    PointerType *ValueType = cast<PointerType>(Val->getType());
    if (Instruction *I = dyn_cast<Instruction>(Val)) {
      Builder.SetInsertPoint(++(I->getIterator()));
    } else {
      Builder.SetInsertPoint(++(TLSBase->getIterator()));
    }

    Value *PtrToInt =
        Builder.CreatePtrToInt(Val, IntptrType, Val->getName() + ".offset");
    Value *AddrValue =
        Builder.CreateAdd(PtrToInt, TLSBase, Val->getName() + ".address");
    Value *NewPtr =
        Builder.CreateIntToPtr(AddrValue, ValueType, Val->getName() + ".tls.ptr");
    Val->replaceUsesWithIf(
        NewPtr, [PtrToInt](Use &U) { return U.getUser() != PtrToInt; });
  }

  PreservedAnalyses PA;
  PA.preserveSet<CFGAnalyses>();
  return PA;
}
