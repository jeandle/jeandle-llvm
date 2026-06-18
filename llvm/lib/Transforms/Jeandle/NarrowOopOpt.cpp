//===- NarrowOopOpt.cpp - Optimization Narrow Oop -------------------------===//
//
// Copyright (c) 2026, the Jeandle-LLVM Authors. All Rights Reserved.
//
// Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM
// Exceptions. See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#include "llvm/Transforms/Jeandle/NarrowOopOpt.h"
#include "llvm/ADT/DenseMap.h"
#include "llvm/ADT/SmallVector.h"
#include "llvm/Analysis/LoopInfo.h"
#include "llvm/IR/Function.h"
#include "llvm/IR/InstIterator.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/Module.h"
#include "llvm/IR/ValueHandle.h"
#include "llvm/Support/Debug.h"
#include "llvm/Transforms/Utils/Local.h"

using namespace llvm;

#define DEBUG_TYPE "narrow-oop-opt"

namespace {

struct OpTable {
  DenseMap<Function *, int> Kind;

  void init(Module &M) {
    auto add = [&](StringRef Name, int K) {
      if (Function *F = M.getFunction(Name))
        Kind[F] = K;
    };
    add("jeandle.encode_heap_oop", +1);
    add("jeandle.decode_heap_oop", -1);
    add("jeandle.encode_klass", +2);
    add("jeandle.decode_klass", -2);
  }

  int lookup(Function *F) const {
    auto It = Kind.find(F);
    return It == Kind.end() ? 0 : It->second;
  }

  bool empty() const { return Kind.empty(); }
};

static Value *tryFoldRoundTrip(Instruction *I, const OpTable &Ops) {
  auto *Outer = dyn_cast<CallInst>(I);
  if (!Outer || Outer->arg_size() != 1)
    return nullptr;

  int OuterKind = Ops.lookup(Outer->getCalledFunction());
  if (OuterKind == 0)
    return nullptr;

  auto *Inner = dyn_cast<CallInst>(Outer->getArgOperand(0));
  if (!Inner || Inner->arg_size() != 1)
    return nullptr;

  int InnerKind = Ops.lookup(Inner->getCalledFunction());
  if (InnerKind == 0)
    return nullptr;

  if (OuterKind + InnerKind != 0)
    return nullptr;

  Value *Original = Inner->getArgOperand(0);

  if (Original->getType() != Outer->getType())
    return nullptr;

  return Original;
}

} // anonymous namespace

PreservedAnalyses NarrowOopOpt::run(Function &F, FunctionAnalysisManager &) {
  OpTable Ops;
  Ops.init(*F.getParent());
  if (Ops.empty())
    return PreservedAnalyses::all();

  bool Changed = false;

  SmallVector<WeakTrackingVH, 32> Candidates;
  for (Instruction &I : instructions(F)) {
    auto *C = dyn_cast<CallInst>(&I);
    if (C && Ops.lookup(C->getCalledFunction()) != 0)
      Candidates.emplace_back(C);
  }

  for (auto &VH : Candidates) {
    auto *I = dyn_cast_or_null<Instruction>(VH);
    if (!I)
      continue;

    Value *Replacement = tryFoldRoundTrip(I, Ops);
    if (!Replacement)
      continue;

    Instruction *MaybeDead = dyn_cast<Instruction>(I->getOperand(0));

    I->replaceAllUsesWith(Replacement);
    I->eraseFromParent();
    Changed = true;

    if (MaybeDead && isInstructionTriviallyDead(MaybeDead))
      MaybeDead->eraseFromParent();
  }

  if (!Changed)
    return PreservedAnalyses::all();
  PreservedAnalyses PA;
  PA.preserveSet<CFGAnalyses>();
  return PA;
}
