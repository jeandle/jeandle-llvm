//===- TypeCheckElimination.cpp - Eliminate redundant type checks ---------===//
//
// Copyright (c) 2025, the Jeandle-LLVM Authors. All Rights Reserved.
//
// Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM
// Exceptions. See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//
//
// This pass eliminates redundant object and Klass subtype checks by using
// compile-time Java type information. Object facts also apply to Klass
// checks whose subtype is loaded directly from a proven non-null object.
//
//===----------------------------------------------------------------------===//

#include "llvm/Transforms/Jeandle/TypeCheckElimination.h"
#include "llvm/Analysis/LazyValueInfo.h"
#include "llvm/IR/Constants.h"
#include "llvm/IR/Dominators.h"
#include "llvm/IR/InstIterator.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/Jeandle/JavaType.h"
#include "llvm/IR/Jeandle/JeandleUtils.h"
#include "llvm/IR/Jeandle/Metadata.h"
#include "llvm/IR/Jeandle/VMCallback.h"
#include "llvm/IR/Module.h"
#include "llvm/Support/Debug.h"
#include "llvm/Transforms/Jeandle/JeandleTransformUtils.h"

#define DEBUG_TYPE "type-check-elimination"

using namespace llvm;

namespace {

/// The caller must establish non-nullness before querying JavaType.
std::optional<bool> evaluateObjectCheck(Value *Obj, uintptr_t SuperKlass,
                                        Instruction *Context,
                                        const jeandle::VMCallbacks &CB,
                                        DominatorTree &DT,
                                        jeandle::IsNullEdgeOracle IsNullEdge) {
  if (CB.IsObjectKlass(SuperKlass))
    return true;

  jeandle::JavaType ObjType =
      jeandle::getJavaType(Obj, &DT, Context, IsNullEdge);
  if ((ObjType.isKnown() && CB.IsSubtype(ObjType.Klass, SuperKlass)) ||
      ObjType.Interfaces.contains(SuperKlass))
    return true;

  if (ObjType.isKnown() &&
      jeandle::areKlassesIncompatible(ObjType.Klass, ObjType.Exact, SuperKlass))
    return false;

  // Excluding X also excludes every subtype of X.
  for (uintptr_t Excluded : ObjType.ExcludedKlasses)
    if (CB.IsSubtype(SuperKlass, Excluded))
      return false;

  return std::nullopt;
}

/// Match only the direct JavaOp, without crossing pointer wrappers or freeze.
CallInst *getObjectKlassLoad(Value *Klass) {
  auto *Load = dyn_cast<CallInst>(Klass);
  Function *Callee = Load ? Load->getCalledFunction() : nullptr;
  if (!Callee || Callee->getName() != "jeandle.load_klass" ||
      Load->getCallingConv() != CallingConv::Hotspot_JIT ||
      Callee->getCallingConv() != CallingConv::Hotspot_JIT ||
      Load->getFunctionType() != Callee->getFunctionType() ||
      Callee->isVarArg() || Load->arg_size() != 1 ||
      Load->getType() != PointerType::get(Load->getContext(), 0) ||
      Load->getArgOperand(0)->getType() !=
          PointerType::get(Load->getContext(), 1) ||
      Load->hasOperandBundles() || Load->isMustTailCall())
    return nullptr;
  return Load;
}

/// Replace a type-check call with a constant result and erase it. The check
/// helpers are only ever emitted as calls (never invokes): an invoke is a
/// terminator, and erasing one would destroy the CFG — so this only accepts
/// CallInst. An invoke-form check simply stays unfolded.
[[nodiscard]] bool foldCheckToConstant(CallInst *Check, Constant *Result) {
  assert(!isa<InvokeInst>(Check) &&
         "check helpers are never emitted as invokes");
  LLVM_DEBUG(dbgs() << "TCE: replacing with constant " << *Result << ": "
                    << *Check << "\n");
  Check->replaceAllUsesWith(Result);
  Check->eraseFromParent();
  return true;
}

} // namespace

PreservedAnalyses TypeCheckElimination::run(Function &F,
                                            FunctionAnalysisManager &FAM) {
  Module *M = F.getParent();
  if (!M->getNamedMetadata(jeandle::Metadata::JavaMethodCompilation))
    return PreservedAnalyses::all();

  const jeandle::VMCallbacks *CB = jeandle::getVMCallbacks();
  assert(CB && CB->IsSubtype && CB->IsInterface && CB->IsObjectKlass &&
         "VMCallbacks must be set");
  if (!CB)
    return PreservedAnalyses::all();

  Function *CheckFn = M->getFunction("jeandle.check_instanceof");
  Function *OffsetCheckFn =
      M->getFunction("jeandle.checkcast_nonnull_with_offset");
  Function *OffsetSubtypeFn =
      M->getFunction("jeandle.check_klass_subtype_with_offset");
  Function *SubtypeFn = M->getFunction("jeandle.check_klass_subtype");
  if (!CheckFn && !OffsetCheckFn && !SubtypeFn && !OffsetSubtypeFn)
    return PreservedAnalyses::all();

  DominatorTree &DT = FAM.getResult<DominatorTreeAnalysis>(F);
  // The LVI snapshot stays safe for the whole pass because TCE only erases
  // non-terminator CallInsts and never splits blocks: LVI's ValueHandles purge
  // erased/RAUW'd values from its caches, and block-value state stays valid
  // while the CFG is unchanged. A fold that touches terminators or blocks
  // would need to drop the oracle first.
  LazyValueInfo &LVI = FAM.getResult<LazyValueAnalysis>(F);
  LVINullEdgeOracle IsNullEdge{LVI};

  // Collect check_instanceof and check_klass_subtype calls. CallInst only:
  // the check helpers are never emitted as invokes, and an invoke must not be
  // erased like a call (it is a terminator) — an invoke-form check simply
  // stays unfolded.
  SmallVector<CallInst *, 16> Checks;
  SmallVector<CallInst *, 16> SubtypeChecks;
  for (auto &I : instructions(F)) {
    auto *Check = dyn_cast<CallInst>(&I);
    if (!Check)
      continue;
    auto Kind = jeandle::getJavaTypeCheckKind(Check);
    if (Kind == jeandle::JavaTypeCheckKind::NonNullObject)
      Checks.push_back(Check);
    if (Kind == jeandle::JavaTypeCheckKind::KlassSubtype)
      SubtypeChecks.push_back(Check);
  }

  // All fold decisions are made against the original IR first and applied
  // afterwards: folding replaces a guard's branch condition with a constant,
  // which would hide the guard from a later check's condition tracing.
  // Deciding every fold up front keeps the result independent of iteration
  // order.
  struct FoldDecision {
    CallInst *Check;
    Constant *Result;
  };
  SmallVector<FoldDecision, 16> Folds;

  // Klass constants are exact descriptors. A direct object Klass load can
  // instead use the object's bounds at the consumer, as with an object check.
  for (CallInst *SubCB : SubtypeChecks) {
    uintptr_t Sub = jeandle::extractKlassConstant(SubCB->getArgOperand(0));
    uintptr_t Super = jeandle::extractKlassConstant(SubCB->getArgOperand(1));
    if (Super == 0)
      continue;
    std::optional<bool> Result;
    if (Sub != 0) {
      Result = CB->IsSubtype(Sub, Super);
    } else if (CallInst *Load = getObjectKlassLoad(SubCB->getArgOperand(0))) {
      Value *Obj = Load->getArgOperand(0);
      // load_klass does not itself promise non-nullness. Keep getClass's
      // dominating null guard and query types only after proving its contract.
      if (DT.dominates(Load, SubCB) &&
          isKnownNonNullAt(Obj, Load, DT, M->getDataLayout(), LVI))
        Result = evaluateObjectCheck(Obj, Super, SubCB, *CB, DT, IsNullEdge);
    }
    if (Result)
      Folds.push_back(
          {SubCB, ConstantInt::get(SubCB->getType(), *Result ? 1 : 0)});
  }
  for (CallInst *CheckCB : Checks) {
    uintptr_t SuperKlass =
        jeandle::extractKlassConstant(CheckCB->getArgOperand(0));
    if (SuperKlass == 0)
      continue;

    // Object-check helpers require a non-null oop at the call site.
    if (auto Result = evaluateObjectCheck(CheckCB->getArgOperand(1), SuperKlass,
                                          CheckCB, *CB, DT, IsNullEdge))
      Folds.push_back(
          {CheckCB, ConstantInt::get(CheckCB->getType(), *Result ? 1 : 0)});
  }

  // --- Apply all folds ---
  bool Changed = false;
  for (const FoldDecision &F : Folds)
    Changed |= foldCheckToConstant(F.Check, F.Result);

  if (!Changed)
    return PreservedAnalyses::all();

  PreservedAnalyses PA;
  PA.preserveSet<CFGAnalyses>();
  PA.preserve<DominatorTreeAnalysis>();
  return PA;
}
