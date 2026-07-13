//===- JeandleNarrowOopMarker.cpp - Mark narrow oop GC roots --------------===//
//
// Copyright (c) 2026, the Jeandle-LLVM Authors. All Rights Reserved.
//
// Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM
// Exceptions. See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#include "llvm/Transforms/Jeandle/JeandleNarrowOopMarker.h"
#include "llvm/ADT/SmallPtrSet.h"
#include "llvm/IR/Constants.h"
#include "llvm/IR/Function.h"
#include "llvm/IR/InstIterator.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/Jeandle/Attributes.h"
#include "llvm/IR/Jeandle/JeandleUtils.hpp"
#include "llvm/IR/Jeandle/Metadata.h"
#include "llvm/IR/Module.h"
#include "llvm/IR/Statepoint.h"

using namespace llvm;

namespace {

constexpr uint64_t NarrowOopMarkerType = 7;
constexpr uint64_t HotSpotTNarrowOop = 16;

// TODO: Update it when DeoptValueEncoding is moved to LLVM side and BasicType
// mirror is added.
uint64_t getNarrowOopMarkerEncoding() {
  // Keep this layout in sync with HotSpot DeoptValueEncoding::encode().
  // The marker has no slot index, so index is zero and the basic type
  // records T_NARROWOOP.
  return (NarrowOopMarkerType << 16) | HotSpotTNarrowOop;
}

} // end anonymous namespace

PreservedAnalyses JeandleNarrowOopMarker::run(Function &F,
                                              FunctionAnalysisManager &) {
  Module *M = F.getParent();

  if (!F.hasFnAttribute(jeandle::Attribute::UseCompressedOops))
    return PreservedAnalyses::all();

  SmallVector<CallBase *, 16> Statepoints;
  for (Instruction &I : instructions(F)) {
    auto *CB = dyn_cast<CallBase>(&I);
    if (CB && isa<GCStatepointInst>(CB))
      Statepoints.push_back(CB);
  }

  bool Changed = false;
  LLVMContext &Ctx = M->getContext();
  uint64_t Marker = getNarrowOopMarkerEncoding();

  for (CallBase *CB : Statepoints) {
    auto *SP = cast<GCStatepointInst>(CB);

    SmallVector<Value *, 16> DeoptInputs;
    if (auto Bundle = SP->getOperandBundle(LLVMContext::OB_deopt)) {
      for (const Use &U : Bundle->Inputs)
        DeoptInputs.push_back(U.get());
    }
    bool NeedSyntheticBci = DeoptInputs.empty();

    SmallPtrSet<Value *, 8> Seen;
    for (const GCRelocateInst *Reloc : SP->getGCRelocates()) {
      Value *Derived = Reloc->getDerivedPtr();
      if (!jeandle::isNarrowOopType(Derived->getType()))
        continue;
      if (!Seen.insert(Derived).second)
        continue;

      DeoptInputs.push_back(ConstantInt::get(Type::getInt64Ty(Ctx), Marker));
      DeoptInputs.push_back(Derived);
    }

    if (Seen.empty())
      continue;

    if (NeedSyntheticBci) {
      // TODO: BCI -1 is valid here: only routine call sites may lack a
      // deopt bundle, and JeandleCompiledCode::resolve_reloc_info treats
      // routine call sites as bci == -1. Remove this path once routine
      // calls carry real deopt bundles.
      //
      // JeandleCompiledCode::parse_stackmap always reads a leading
      // should_reexecute flag before the duplicated-bci pair. A synthetic
      // bundle must include it too, or the reader misinterprets this bci
      // as should_reexecute and desyncs every value after it.
      //
      // should_reexecute is i64 (see JeandleAbstractInterpreter::deopt_args)
      // so it can't be mistaken for one half of the duplicated-bci i32 pair.
      Value *SyntheticShouldReexecute =
          ConstantInt::get(Type::getInt64Ty(Ctx), 0);
      Value *SyntheticBci = ConstantInt::get(Type::getInt32Ty(Ctx), -1);
      DeoptInputs.insert(DeoptInputs.begin(), {SyntheticShouldReexecute,
                                               SyntheticBci, SyntheticBci});
    }

    OperandBundleDef NewDeopt("deopt", DeoptInputs);
    CallBase *NewCB = CallBase::Create(CB, NewDeopt, CB->getIterator());
    NewCB->takeName(CB);
    CB->replaceAllUsesWith(NewCB);
    CB->eraseFromParent();
    Changed = true;
  }

  return Changed ? PreservedAnalyses::none() : PreservedAnalyses::all();
}
