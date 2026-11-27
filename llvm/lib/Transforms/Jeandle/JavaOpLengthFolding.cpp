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

#include "llvm/ADT/DenseMap.h"
#include "llvm/ADT/SmallPtrSet.h"
#include "llvm/ADT/SmallVector.h"
#include "llvm/ADT/Statistic.h"
#include "llvm/Analysis/AssumptionCache.h"
#include "llvm/Analysis/Jeandle/PartialEscapeUtils.h"
#include "llvm/Analysis/ValueTracking.h"
#include "llvm/IR/Dominators.h"
#include "llvm/IR/Function.h"
#include "llvm/IR/IRBuilder.h"
#include "llvm/IR/InstrTypes.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/Jeandle/JeandleUtils.h"
#include "llvm/IR/Jeandle/Metadata.h"
#include "llvm/IR/Module.h"
#include "llvm/IR/ValueHandle.h"
#include "llvm/Transforms/Utils/Local.h"

#define DEBUG_TYPE "jeandle-java-op-length-folding"

STATISTIC(NumResolveNodesExpanded,
          "Number of merge nodes expanded during arraylength resolution");
STATISTIC(NumResolveCacheHits,
          "Number of cache hits during arraylength resolution");

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

struct ResolveStepResult {
  ResolveResult Result;
  // False if the outcome depended on an in-progress cycle back-edge, a
  // self-edge, or a depth-limit cutoff. Only context-independent completed
  // results may be memoized within a query.
  bool Cacheable = true;
};

// Bound on the recursion depth over PHI/select chains. Pathological merge
// diamonds give up conservatively instead of burning compile time.
static constexpr unsigned MaxResolveDepth = 16;

// Cache key pairs the canonicalized merge node (PHI/select after stripping
// identity wrappers and zero-offset GEPs) with the current recursion depth so
// cached entries preserve the exact remaining depth budget.
using ResolveCacheKey = std::pair<Value *, unsigned>;
using ResolveCache = SmallDenseMap<ResolveCacheKey, ResolveResult, 16>;

static ResolveStepResult
resolveArrayLength(Value *V, const DataLayout &DL, unsigned Depth,
                   SmallPtrSetImpl<Value *> &Active,
                   SmallPtrSetImpl<Value *> &Allocations, ResolveCache &Cache) {
  if (Depth > MaxResolveDepth)
    return {{ResolveKind::Conflict, nullptr}, /*Cacheable=*/false};

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
    return {{ResolveKind::Conflict, nullptr}, /*Cacheable=*/true};

  if (auto *CB = dyn_cast<CallBase>(Root)) {
    if (Value *Length = jeandle::pea::getJeandleNewArrayLength(CB)) {
      Allocations.insert(CB);
      return {{ResolveKind::Resolved, Length}, /*Cacheable=*/true};
    }
    return {{ResolveKind::Conflict, nullptr}, /*Cacheable=*/true};
  }

  // PHI and select merge several candidate arrays. All non-cycle incomings
  // must resolve to the SAME length Value (pointer equality; constants are
  // context-uniqued, so equal constants compare equal).
  if (!isa<PHINode>(Root) && !isa<SelectInst>(Root)) {
    // Function arguments, loads, other calls, undef/poison, ... — opaque.
    return {{ResolveKind::Conflict, nullptr}, /*Cacheable=*/true};
  }

  if (Active.contains(Root))
    return {{ResolveKind::NoInfo, nullptr},
            /*Cacheable=*/false}; // cycle back-edge

  ResolveCacheKey Key{Root, Depth};
  if (auto It = Cache.find(Key); It != Cache.end()) {
    ++NumResolveCacheHits;
    return {It->second, /*Cacheable=*/true};
  }

  Active.insert(Root);
  ++NumResolveNodesExpanded;

  SmallVector<Value *, 4> Incomings;
  if (auto *PN = dyn_cast<PHINode>(Root)) {
    for (Value *Inc : PN->incoming_values())
      Incomings.push_back(Inc);
  } else {
    auto *SI = cast<SelectInst>(Root);
    Incomings.push_back(SI->getTrueValue());
    Incomings.push_back(SI->getFalseValue());
  }

  ResolveResult Acc{ResolveKind::NoInfo, nullptr};
  bool Cacheable = true;
  for (Value *Inc : Incomings) {
    if (Inc == Root) {
      Cacheable = false;
      continue; // self-edge adds no new value
    }
    ResolveStepResult Step =
        resolveArrayLength(Inc, DL, Depth + 1, Active, Allocations, Cache);
    Cacheable &= Step.Cacheable;
    ResolveResult R = Step.Result;
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
  if (Cacheable && Acc.Kind != ResolveKind::NoInfo)
    Cache.try_emplace(Key, Acc);
  return {Acc, Cacheable};
}

// Dead pointer wrappers can keep an otherwise unused allocation alive after
// folding. Bound the walk, and leave live merges (including deopt uses) alone.
static void removeDeadWrappers(CallBase &Allocation) {
  SmallVector<WeakTrackingVH, 16> Worklist{&Allocation};
  SmallPtrSet<Value *, 32> Seen;
  Seen.insert(&Allocation);
  for (unsigned I = 0; I < Worklist.size() && Worklist.size() < 64; ++I) {
    Value *V = Worklist[I];
    for (User *U : V->users()) {
      auto *Inst = dyn_cast<Instruction>(U);
      if (Inst && Inst->getType()->isPointerTy() &&
          (isa<CastInst>(Inst) || isa<GetElementPtrInst>(Inst) ||
           isa<FreezeInst>(Inst) || isa<PHINode>(Inst) ||
           isa<SelectInst>(Inst)) &&
          Seen.insert(Inst).second) {
        Worklist.push_back(Inst);
        if (Worklist.size() == 64)
          break;
      }
    }
  }
  for (const WeakTrackingVH &H : reverse(Worklist)) {
    auto *I = dyn_cast_or_null<Instruction>(H);
    if (I && I != &Allocation && isInstructionTriviallyDead(I))
      I->eraseFromParent();
  }
}

static bool canRemoveUnusedArray(CallBase &CB) {
  if (!CB.use_empty() || !jeandle::pea::isJeandleNewArrayCall(&CB) ||
      (!isa<CallInst>(CB) && !isa<InvokeInst>(CB)) ||
      !CB.getType()->isPointerTy() ||
      CB.getType()->getPointerAddressSpace() != 1 ||
      !CB.getArgOperand(0)->getType()->isPointerTy())
    return false;
  for (unsigned I = 1; I != 5; ++I)
    if (!CB.getArgOperand(I)->getType()->isIntegerTy(32))
      return false;
  auto *Uninitialized = dyn_cast<ConstantInt>(CB.getArgOperand(5));
  auto *Deferred = dyn_cast<ConstantInt>(CB.getArgOperand(6));
  if (!Uninitialized || !Uninitialized->getType()->isIntegerTy(1) ||
      !Deferred || !Deferred->getType()->isIntegerTy(1) || !Deferred->isZero())
    return false;
  auto Element = jeandle::elementTypeForArrayKlass(
      jeandle::pea::extractAllocationKlass(&CB));
  return Element != jeandle::JBasicType::Count &&
         (Uninitialized->isZero() || Element != jeandle::JBasicType::Object);
}

// Keep the original call, BCI, bundles and exception edge for negative lengths.
// The new edge bypasses only an allocation whose object has no remaining uses.
static void bypassUnusedArray(CallBase &CB, bool NonNegative) {
  if (NonNegative) {
    if (auto *II = dyn_cast<InvokeInst>(&CB)) {
      II->getUnwindDest()->removePredecessor(II->getParent());
      BranchInst::Create(II->getNormalDest(), II->getIterator());
    }
    CB.eraseFromParent();
    return;
  }

  BasicBlock *Before = CB.getParent();
  BasicBlock *Slow =
      Before->splitBasicBlock(CB.getIterator(), "arraylength.negative_length");
  BasicBlock *Normal;
  if (auto *II = dyn_cast<InvokeInst>(&CB)) {
    Normal = II->getNormalDest();
    for (PHINode &PN : Normal->phis())
      PN.addIncoming(PN.getIncomingValueForBlock(Slow), Before);
  } else {
    Normal = Slow->splitBasicBlock(std::next(CB.getIterator()),
                                   "arraylength.continue");
  }
  IRBuilder<> B(Before->getTerminator());
  Value *Negative = B.CreateICmpSLT(CB.getArgOperand(1), B.getInt32(0),
                                    "arraylength.is_negative");
  B.CreateCondBr(Negative, Slow, Normal);
  Before->getTerminator()->eraseFromParent();
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
  SmallVector<WeakTrackingVH, 8> Candidates;
  SmallPtrSet<Value *, 16> CandidateSet;
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
      SmallPtrSet<Value *, 8> Allocations;
      ResolveCache Cache;
      ResolveResult R =
          resolveArrayLength(CB->getArgOperand(0), DL,
                             /*Depth=*/0, Active, Allocations, Cache)
              .Result;
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
      for (Value *Allocation : Allocations)
        if (CandidateSet.insert(Allocation).second)
          Candidates.push_back(Allocation);
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

  // Finish all analysis queries before changing the allocation CFG. Length
  // invokes above may already have removed edges, so refresh dominance first.
  if (ChangedCFG)
    DT.recalculate(F);
  AssumptionCache &AC = FAM.getResult<AssumptionAnalysis>(F);
  SmallVector<std::pair<WeakTrackingVH, bool>, 8> Unused;
  for (const WeakTrackingVH &H : Candidates) {
    auto *CB = dyn_cast_or_null<CallBase>(H);
    if (!CB)
      continue;
    removeDeadWrappers(*CB);
    if (!canRemoveUnusedArray(*CB))
      continue;
    Value *Length = CB->getArgOperand(1);
    if (auto *C = dyn_cast<ConstantInt>(Length))
      if (C->isNegative())
        continue;
    Unused.push_back(
        {CB, isKnownNonNegative(Length, SimplifyQuery(DL, &DT, &AC, CB))});
  }
  for (auto &[H, NonNegative] : Unused) {
    if (auto *CB = dyn_cast_or_null<CallBase>(H)) {
      bypassUnusedArray(*CB, NonNegative);
      ChangedCFG = true;
    }
  }

  if (ChangedCFG)
    return PreservedAnalyses::none();
  PreservedAnalyses PA;
  PA.preserveSet<CFGAnalyses>(); // calls erased in place, CFG untouched
  return PA;
}
