//===- CachedJavaType.h - Cached current Java type queries ----*- C++ -*-===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#ifndef LLVM_ANALYSIS_JEANDLE_CACHEDJAVATYPE_H
#define LLVM_ANALYSIS_JEANDLE_CACHEDJAVATYPE_H

#include "llvm/Analysis/Jeandle/JavaTypeCache.h"

namespace llvm::jeandle {

/// Query the shared JavaType algorithm with caches. The caller owns
/// all four caches and maintains their invalidation before IR changes. Base
/// and definedness share completed value results; Facts shares cumulative
/// paths; Final shares complete top-level queries until an IR/oracle
/// notification. Cache classes own their counters. No query stacks or budgets
/// persist.
LLVM_ABI JavaType getCachedJavaType(Value *V, DominatorTree *DT,
                                    Instruction *Context,
                                    IsNullEdgeOracle IsNullEdge,
                                    JavaTypeCache &Cache);

} // namespace llvm::jeandle

#endif // LLVM_ANALYSIS_JEANDLE_CACHEDJAVATYPE_H
