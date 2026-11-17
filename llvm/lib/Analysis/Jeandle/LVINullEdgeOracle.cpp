//===- LVINullEdgeOracle.cpp - LVI-backed Java null-edge queries
//------------===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#include "llvm/Analysis/Jeandle/LVINullEdgeOracle.h"
#include "llvm/ADT/SmallPtrSet.h"
#include "llvm/ADT/SmallVector.h"
#include "llvm/Analysis/LazyValueInfo.h"
#include "llvm/IR/Constants.h"
#include "llvm/IR/GlobalAlias.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/Jeandle/JavaType.h"
#include "llvm/IR/Operator.h"
#include "llvm/Support/CommandLine.h"

using namespace llvm;

namespace {
cl::opt<bool> DisableNullEdgePrefilter(
    "jeandle-disable-null-edge-prefilter", cl::Hidden, cl::init(false),
    cl::desc("Disable the query-local negative filter for LVI null edges"));

Value *canonicalNullValue(Value *V) {
  while (true) {
    V = V->stripPointerCastsAndAliases();
    auto *FI = dyn_cast<FreezeInst>(V);
    if (!FI || !jeandle::isProvenDefined(FI->getOperand(0)))
      return V;
    V = FI->getOperand(0);
  }
}
} // namespace

bool LVINullEdgeQuery::spendWork() {
  if (WorkRemaining) {
    --WorkRemaining;
    return true;
  }
  if (!LimitHit && CollectStats)
    ++Counters.FilterFallbacks;
  LimitHit = true;
  return false;
}

// Absence of tests is established over a bounded use closure, independent of
// dominance. Any comparison or unsupported operation keeps the LVI fallback.
// Follow select/PHI and identity users too: a test of a derived value may
// constrain its input. Calls without a returned argument and memory/return
// uses cannot positively prove their pointer operand null in LVI.
bool LVINullEdgeQuery::hasPotentialTest(Value *V) {
  if (auto It = HasTests.find(V); It != HasTests.end())
    return It->second;
  SmallVector<Value *, 16> Pending{V};
  SmallPtrSet<Value *, 32> Seen;
  while (!Pending.empty()) {
    Value *Cur = Pending.pop_back_val();
    if (!Seen.insert(Cur).second)
      continue;
    if (auto It = HasTests.find(Cur); It != HasTests.end()) {
      if (It->second)
        return HasTests[V] = true;
      continue;
    }
    // ConstantData and unused values have no materialized use list, so
    // iterating users() would trip an assertion in assertion-enabled builds.
    if (Cur->use_empty())
      continue;
    for (User *U : Cur->users()) {
      if (!spendWork())
        return HasTests[V] = true;
      if (isa<ICmpInst, PtrToIntInst>(U))
        return HasTests[V] = true;
      if (isa<GlobalAlias, BitCastInst, AddrSpaceCastInst, FreezeInst,
              SelectInst, PHINode>(U)) {
        Pending.push_back(U);
        continue;
      }
      if (auto *GEP = dyn_cast<GEPOperator>(U)) {
        if (!GEP->hasAllZeroIndices())
          return HasTests[V] = true;
        Pending.push_back(U);
        continue;
      }
      if (auto *CE = dyn_cast<ConstantExpr>(U)) {
        if (CE->getOpcode() != Instruction::BitCast &&
            CE->getOpcode() != Instruction::AddrSpaceCast)
          return HasTests[V] = true;
        Pending.push_back(U);
        continue;
      }
      if (auto *CB = dyn_cast<CallBase>(U)) {
        if (CB->getReturnedArgOperand() == Cur)
          Pending.push_back(U);
        continue;
      }
      if (isa<LoadInst, StoreInst, ReturnInst>(U))
        continue;
      return HasTests[V] = true;
    }
  }
  for (Value *Cur : Seen)
    HasTests[Cur] = false;
  return false;
}

// Filter only when neither a use-side condition nor the value's definition
// can supply a null constant. OR is intentionally conservative for PHI/select:
// one feasible null arm is enough to retain LVI, even if another arm is
// unknown.
bool LVINullEdgeQuery::mayNeedLVI(Value *V, unsigned Depth) {
  V = canonicalNullValue(V);
  if (auto It = NeedsLVI.find(V); It != NeedsLVI.end())
    return It->second;
  if (Depth > 64) {
    if (!LimitHit && CollectStats)
      ++Counters.FilterFallbacks;
    LimitHit = true;
    return true;
  }
  if (!spendWork())
    return true;
  NeedsLVI[V] = true; // Cycles retain LVI; no incomplete negative is published.
  if (hasPotentialTest(V))
    return true;
  bool Needed = true;
  if (isa<Argument>(V)) {
    Needed = false;
  } else if (auto *SI = dyn_cast<SelectInst>(V)) {
    if (auto *C = dyn_cast<ConstantInt>(SI->getCondition()))
      Needed = mayNeedLVI(
          C->isZero() ? SI->getFalseValue() : SI->getTrueValue(), Depth + 1);
    else
      Needed = mayNeedLVI(SI->getTrueValue(), Depth + 1) ||
               mayNeedLVI(SI->getFalseValue(), Depth + 1);
  } else if (auto *PN = dyn_cast<PHINode>(V)) {
    Needed = PN->getNumIncomingValues() == 0;
    for (Value *Input : PN->incoming_values())
      if (mayNeedLVI(Input, Depth + 1)) {
        Needed = true;
        break;
      }
  }
  // Constants, returned calls, loads, inttoptr and unproven freezes fall back.
  // Their lattice folding is deliberately left to LVI.
  NeedsLVI[V] = Needed;
  return Needed;
}

/// LazyValueInfo-backed null-edge oracle. This fork's getPredicateOnEdge
/// returns a Constant*: the constant result of the comparison, or nullptr when
/// unknown. Unknown answers false (the edge is kept) — only positive proof may
/// skip an edge. Pointer casts and aliases are stripped; a freeze is stripped
/// only when its operand is proven defined, so null proofs describe the
/// queried value even when it is produced by freezing poison.
bool LVINullEdgeOracle::operator()(Value *V, BasicBlock *FromBB,
                                   BasicBlock *ToBB) const {
  if (Query && Query->CollectStats)
    ++Query->Counters.Requests;
  V = canonicalNullValue(V);
  auto *PT = dyn_cast<PointerType>(V->getType());
  if (!PT)
    return false;

  // Structural fast path for the edge's own terminator: a conditional branch
  // on `icmp eq/ne TESTED, null` answers the query directly, for either
  // operand order and through pointer casts on the tested value — forms the
  // LVI query below does not reliably recover. A conclusive answer on the
  // tested edge is also final: the non-null side of a direct null test can
  // never be a null edge.
  if (auto *BI = dyn_cast<BranchInst>(FromBB->getTerminator()))
    if (BI->isConditional() && BI->getSuccessor(0) != BI->getSuccessor(1))
      if (auto *Cmp = dyn_cast<ICmpInst>(BI->getCondition()))
        if (Cmp->getPredicate() == ICmpInst::ICMP_EQ ||
            Cmp->getPredicate() == ICmpInst::ICMP_NE) {
          Value *Op0 = Cmp->getOperand(0);
          Value *Op1 = Cmp->getOperand(1);
          Value *Tested =
              isa<ConstantPointerNull>(Op0->stripPointerCastsAndAliases())
                  ? Op1
                  : (isa<ConstantPointerNull>(
                         Op1->stripPointerCastsAndAliases())
                         ? Op0
                         : nullptr);
          if (Tested && Tested->stripPointerCastsAndAliases() == V) {
            // eq: the true successor is the null side; ne: the false one.
            BasicBlock *NullBB = Cmp->getPredicate() == ICmpInst::ICMP_EQ
                                     ? BI->getSuccessor(0)
                                     : BI->getSuccessor(1);
            if (Query && Query->CollectStats)
              ++Query->Counters.Structural;
            return NullBB == ToBB;
          }
        }

  if (Query && !DisableNullEdgePrefilter && !Query->mayNeedLVI(V)) {
    if (Query->CollectStats)
      ++Query->Counters.Filtered;
    return false;
  }
  if (Query && Query->CollectStats)
    ++Query->Counters.LVICalls;
  Constant *C = LVI.getPredicateOnEdge(
      ICmpInst::ICMP_EQ, V, ConstantPointerNull::get(PT), FromBB, ToBB);
  return C && C->isOneValue();
}
