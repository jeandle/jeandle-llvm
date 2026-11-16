//===- JeandleAnalysisUtils.cpp - Analysis utilities ----------------------===//
//
// Copyright (c) 2026, the Jeandle-LLVM Authors. All Rights Reserved.
// Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM
// Exceptions. See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#include "llvm/Analysis/Jeandle/JeandleAnalysisUtils.h"
#include "llvm/Analysis/LazyValueInfo.h"
#include "llvm/IR/Constants.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/Jeandle/JavaType.h"

using namespace llvm;

/// LazyValueInfo-backed null-edge oracle. This fork's getPredicateOnEdge
/// returns a Constant*: the constant result of the comparison, or nullptr when
/// unknown. Unknown answers false (the edge is kept) — only positive proof may
/// skip an edge. Pointer casts and aliases are stripped; a freeze is stripped
/// only when its operand is proven defined, so null proofs describe the
/// queried value even when it is produced by freezing poison.
bool LVINullEdgeOracle::operator()(Value *V, BasicBlock *FromBB,
                                   BasicBlock *ToBB) const {
  while (true) {
    V = V->stripPointerCastsAndAliases();
    if (auto *FI = dyn_cast<FreezeInst>(V)) {
      if (!jeandle::isProvenDefined(FI->getOperand(0)))
        break;
      V = FI->getOperand(0);
      continue;
    }
    break;
  }
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
            return NullBB == ToBB;
          }
        }

  Constant *C = LVI.getPredicateOnEdge(
      ICmpInst::ICMP_EQ, V, ConstantPointerNull::get(PT), FromBB, ToBB);
  return C && C->isOneValue();
}
