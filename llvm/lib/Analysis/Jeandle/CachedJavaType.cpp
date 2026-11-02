//===- CachedJavaType.cpp - Cached Java type query entry ------------------===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#include "llvm/Analysis/Jeandle/CachedJavaType.h"
#include "llvm/ADT/ScopeExit.h"
#include "llvm/IR/Instructions.h"

using namespace llvm;
using namespace llvm::jeandle;

JavaType jeandle::getCachedJavaType(Value *V, DominatorTree *DT,
                                     Instruction *Context,
                                     IsNullEdgeOracle IsNullEdge,
                                     JavaTypeCache &Cache) {
  if (Context)
    Cache.bind(*Context->getFunction());
  else if (auto *I = dyn_cast<Instruction>(V))
    Cache.bind(*I->getFunction());
  else if (auto *A = dyn_cast<Argument>(V))
    Cache.bind(*A->getParent());

  BasicBlock *BB = DT && Context ? Context->getParent() : nullptr;
  if (BB && Cache.finalEnabled()) {
    if (auto *Type = Cache.Final.lookup(V, BB)) {
      Cache.Final.recordHit();
      return *Type;
    }
    Cache.Final.recordMiss();
  }

  Cache.Base.beginQuery();
  auto Finish = make_scope_exit([&] { Cache.Base.endQuery(); });
  JavaType Result = jeandle::getJavaType(V, DT, Context, IsNullEdge, Cache);
  // Only the completed top-level result is published. Recursive evaluations
  // stay in the shared solver and never read or write Final.
  if (BB && Cache.finalEnabled())
    Cache.Final.insert(V, BB, Result);
  return Result;
}
