//===- JavaOpLengthFolding.cpp - Fold arraylength of new_array ------------===//
//
// Copyright (c) 2026, the Jeandle-LLVM Authors. All Rights Reserved.
//
// Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM
// Exceptions. See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//
//
// Folds jeandle.arraylength(X) to the new_array length argument when X
// provably refers only to jeandle.new_array allocations that all share the
// same length value.
//
// Why this is semantics-preserving: on the normal-return path the array
// header's length field holds exactly the `%length` argument passed to
// jeandle.new_array (the TLAB fast path stores it directly, the slow path
// allocates with the same argument). A negative length takes the slow path
// and throws NegativeArraySizeException, so the invoke never reaches its
// normal destination and the arraylength call is unreachable. If the length
// argument were poison, the new_array call itself is already UB.
//
// Why this pass exists: the frontend emits jeandle.arraylength both for the
// arraylength bytecode and for every array bounds check. It is the ONLY
// reader of the array length field before JavaOperationLower(1). PEA folds
// arraylength of virtual objects internally (foldArrayLength), but that is
// too late for loop unrolling: the unroller needs a constant trip count
// BEFORE PEA runs. Folding here lets LoopRotate/IndVarSimplify/LoopUnroll
// turn `for (i < array.length) array[i] = 0` into straight-line
// constant-offset stores that PEA can virtualize, and constant-folds the
// per-element bounds checks in the unrolled body.
//
// The argument of jeandle.arraylength can be ANY ptr addrspace(1) value, so
// resolution is a bounded three-state recursion over casts, GEPs, PHIs, and
// selects (see resolveArrayLength). Conditional merges AND loop-carried
// PHIs are both handled; the cycle rule (a back-edge into an in-progress
// PHI contributes NoInfo) is sound because a cycle adds no values beyond
// the least fixed point of the non-cycle incomings:
//   a = phi(alloc10, b); b = phi(a, alloc20)
// values(a) = values(alloc10) u values(b), values(b) = values(a) u
// values(alloc20); the fixpoint is {alloc10, alloc20}, so the a-incoming of
// b contributes nothing new, and a correctly resolves to Conflict (10 != 20).
//
//===----------------------------------------------------------------------===//

#include "llvm/Transforms/Jeandle/JavaOpLengthFolding.h"

#include "llvm/ADT/SmallPtrSet.h"
#include "llvm/ADT/SmallVector.h"
#include "llvm/Analysis/Jeandle/PartialEscapeUtils.h"
#include "llvm/IR/Dominators.h"
#include "llvm/IR/Function.h"
#include "llvm/IR/InstrTypes.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/Jeandle/Metadata.h"
#include "llvm/IR/Module.h"
#include "llvm/IR/ValueHandle.h"

#define DEBUG_TYPE "jeandle-java-op-length-folding"

using namespace llvm;

namespace {

// Outcome of resolving one pointer expression to a unique array length.
enum class ResolveKind {
  Resolved, // Provably refers only to new_array allocations sharing Length.
  NoInfo,   // Contributes no new values (a cycle back-edge into an
            // in-progress PHI/select).
  Conflict, // Cannot prove a unique length (non-new_array leaf, disagreeing
            // arms, undef/poison, depth exceeded).
};
struct ResolveResult {
  ResolveKind Kind;
  Value *Length; // valid only when Kind == Resolved
};

// Bound on the recursion depth over PHI/select chains. Pathological merge
// diamonds give up conservatively instead of burning compile time.
static constexpr unsigned MaxResolveDepth = 16;

static ResolveResult resolveArrayLength(Value *V, const DataLayout &DL,
                                        unsigned Depth,
                                        SmallPtrSetImpl<Value *> &Active) {
  if (Depth > MaxResolveDepth)
    return {ResolveKind::Conflict, nullptr};

  // Peel identity-preserving wrappers (bitcast, addrspacecast within
  // addrspace(1), freeze) and constant-offset GEPs — the same helper PEA
  // uses for object identity, so the two agree on which laundered pointers
  // are transparent. Only a whole-object reference (offset 0) may fold: a
  // derived pointer into the middle of an array is not the array.
  int64_t Offset = 0;
  bool NonConstant = false;
  Value *Root =
      jeandle::pea::stripPointerCastsAndOffsets(V, DL, &Offset, &NonConstant);
  if (NonConstant || Offset != 0 || !Root)
    return {ResolveKind::Conflict, nullptr};

  if (auto *CB = dyn_cast<CallBase>(Root)) {
    if (Value *Length = jeandle::pea::getJeandleNewArrayLength(CB))
      return {ResolveKind::Resolved, Length};
    return {ResolveKind::Conflict, nullptr};
  }

  // PHI and select merge several candidate arrays. All non-cycle incomings
  // must resolve to the SAME length Value (pointer equality; constants are
  // context-uniqued, so equal constants compare equal).
  SmallVector<Value *, 4> Incomings;
  if (auto *PN = dyn_cast<PHINode>(Root)) {
    if (!Active.insert(PN).second)
      return {ResolveKind::NoInfo, nullptr}; // cycle back-edge
    for (Value *Inc : PN->incoming_values())
      Incomings.push_back(Inc);
  } else if (auto *SI = dyn_cast<SelectInst>(Root)) {
    if (!Active.insert(SI).second)
      return {ResolveKind::NoInfo, nullptr};
    Incomings.push_back(SI->getTrueValue());
    Incomings.push_back(SI->getFalseValue());
  } else {
    // Function arguments, loads, other calls, undef/poison, ... — opaque.
    return {ResolveKind::Conflict, nullptr};
  }

  ResolveResult Acc{ResolveKind::NoInfo, nullptr};
  for (Value *Inc : Incomings) {
    if (Inc == Root)
      continue; // self-edge adds no new value
    ResolveResult R = resolveArrayLength(Inc, DL, Depth + 1, Active);
    if (R.Kind == ResolveKind::Conflict) {
      Acc = R;
      break;
    }
    if (R.Kind == ResolveKind::NoInfo)
      continue;
    if (Acc.Kind == ResolveKind::NoInfo)
      Acc = R;
    else if (Acc.Length != R.Length) {
      Acc = {ResolveKind::Conflict, nullptr};
      break;
    }
  }
  Active.erase(Root);
  return Acc;
}

} // end anonymous namespace

PreservedAnalyses JavaOpLengthFolding::run(Function &F,
                                           FunctionAnalysisManager &FAM) {
  // Gate on jeandle.java_method_compilation, mirroring PartialEscapeIterative.
  Module *M = F.getParent();
  if (!M || !M->getNamedMetadata(jeandle::Metadata::JavaMethodCompilation))
    return PreservedAnalyses::all();

  DominatorTree &DT = FAM.getResult<DominatorTreeAnalysis>(F);
  const DataLayout &DL = M->getDataLayout();

  // Collect folds first, apply after the walk. WeakTrackingVH handles
  // chains like %l1 = arraylength(new(7)); %a1 = new_array(%l1);
  // %l2 = arraylength(%a1): %l2's recorded length IS the %l1 call, which a
  // sibling fold RAUWs (to 7) and erases — the handle follows the RAUW.
  struct Fold {
    WeakTrackingVH CB;
    WeakTrackingVH Len;
  };
  SmallVector<Fold, 8> Folds;
  for (BasicBlock &BB : F) {
    for (Instruction &I : BB) {
      auto *CB = dyn_cast<CallBase>(&I);
      if (!CB || !jeandle::pea::isJeandleArrayLength(CB) || CB->arg_size() != 1)
        continue;
      // Only plain calls and invokes are foldable forms; anything more
      // exotic (callbr, ...) is left untouched.
      if (!isa<CallInst>(CB) && !isa<InvokeInst>(CB))
        continue;

      SmallPtrSet<Value *, 8> Active;
      ResolveResult R =
          resolveArrayLength(CB->getArgOperand(0), DL, /*Depth=*/0, Active);
      if (R.Kind != ResolveKind::Resolved)
        continue;

      Value *Len = R.Length;
      if (Len->getType() != CB->getType())
        continue; // non-standard declaration; both are i32 in practice.

      // Dominance is REQUIRED, not merely defensive: a length defined inside
      // a loop (e.g. feeding a back-edge new_array) legally dominates the
      // back edge but NOT an arraylength call after the loop. Constants and
      // arguments need no check.
      if (auto *LenI = dyn_cast<Instruction>(Len))
        if (!DT.dominates(LenI, CB))
          continue;

      Folds.push_back({CB, Len});
    }
  }

  if (Folds.empty())
    return PreservedAnalyses::all();

  bool ChangedCFG = false;
  for (auto &[CBH, LenH] : Folds) {
    auto *CB = cast_or_null<CallBase>(CBH);
    Value *Len = LenH;
    if (!CB || !Len || Len->getType() != CB->getType())
      continue;
    if (auto *II = dyn_cast<InvokeInst>(CB)) {
      // Invoke form (not emitted by the frontend today, but earlier passes
      // or a future frontend may produce it): turn it into an unconditional
      // branch to the normal dest, mirroring PEA's eraseAllocation. The
      // arraylength result's uses are all on the normal edge and are
      // covered by the dominance check above.
      BasicBlock *Normal = II->getNormalDest();
      BasicBlock *Unwind = II->getUnwindDest();
      II->replaceAllUsesWith(Len);
      BranchInst::Create(Normal, II->getIterator());
      Unwind->removePredecessor(II->getParent());
      II->eraseFromParent();
      ChangedCFG = true;
    } else {
      CB->replaceAllUsesWith(Len);
      CB->eraseFromParent();
    }
  }

  if (ChangedCFG)
    return PreservedAnalyses::none();
  PreservedAnalyses PA;
  PA.preserveSet<CFGAnalyses>(); // calls erased in place, CFG untouched
  return PA;
}
