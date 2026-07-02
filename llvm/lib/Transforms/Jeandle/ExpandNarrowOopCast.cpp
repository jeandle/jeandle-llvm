//===- ExpandNarrowOopCast.cpp - Expand narrow oop casts -----------------===//
//
// Copyright (c) 2026, the Jeandle-LLVM Authors. All Rights Reserved.
//
// Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM
// Exceptions. See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#include "llvm/Transforms/Jeandle/ExpandNarrowOopCast.h"
#include "llvm/ADT/SmallVector.h"
#include "llvm/IR/Function.h"
#include "llvm/IR/IRBuilder.h"
#include "llvm/IR/InstIterator.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/Jeandle/Metadata.h"
#include "llvm/IR/Module.h"
#include "llvm/Support/Debug.h"

using namespace llvm;

#define DEBUG_TYPE "expand-narrow-oop-cast"

namespace {

static unsigned getPointerAddressSpace(Type *Ty) {
  auto *PT = dyn_cast<PointerType>(Ty);
  return PT ? PT->getAddressSpace() : ~0U;
}

} // end anonymous namespace

PreservedAnalyses ExpandNarrowOopCast::run(Function &F,
                                          FunctionAnalysisManager &) {
  Module *M = F.getParent();

  // Only java method compilations need gc barriers.
  if (!M->getNamedMetadata(jeandle::Metadata::JavaMethodCompilation))
    return PreservedAnalyses::all();

  SmallVector<AddrSpaceCastInst *, 16> Casts;
  for (Instruction &I : instructions(F))
    if (auto *Cast = dyn_cast<AddrSpaceCastInst>(&I))
      Casts.push_back(Cast);

  if (Casts.empty())
    return PreservedAnalyses::all();

  Function *Encode = M->getFunction("jeandle.encode_heap_oop");
  assert(Encode != nullptr && "jeandle.encode_heap_oop must exist");
  Function *Decode = M->getFunction("jeandle.decode_heap_oop");
  assert(Decode != nullptr && "jeandle.decode_heap_oop must exist");

  bool Changed = false;
  for (AddrSpaceCastInst *Cast : Casts) {
    unsigned SrcAS = getPointerAddressSpace(Cast->getOperand(0)->getType());
    unsigned DstAS = getPointerAddressSpace(Cast->getType());

    Function *Callee = nullptr;
    if (SrcAS == jeandle::AddrSpace::JavaHeapAddrSpace &&
        DstAS == jeandle::AddrSpace::NarrowOopAddrSpace) {
      Callee = Encode;
    } else if (SrcAS == jeandle::AddrSpace::NarrowOopAddrSpace &&
               DstAS == jeandle::AddrSpace::JavaHeapAddrSpace) {
      Callee = Decode;
    } else {
      continue;
    }

    IRBuilder<> Builder(Cast);
    CallInst *Call = Builder.CreateCall(Callee, {Cast->getOperand(0)});
    Call->setCallingConv(CallingConv::Hotspot_JIT);
    Cast->replaceAllUsesWith(Call);
    Cast->eraseFromParent();
    Changed = true;
  }

  if (!Changed)
    return PreservedAnalyses::all();

  PreservedAnalyses PA;
  PA.preserveSet<CFGAnalyses>();
  return PA;
}
