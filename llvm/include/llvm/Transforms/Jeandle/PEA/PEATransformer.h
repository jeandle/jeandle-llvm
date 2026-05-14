//===- PEATransformer.h - PEA Transformer Pass ---------------------------===//
//
// Copyright (c) 2026, the Jeandle-LLVM Authors. All Rights Reserved.
//
// Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM
// Exceptions. See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#ifndef LLVM_TRANSFORMS_JEANDLE_PEA_TRANSFORMER_H
#define LLVM_TRANSFORMS_JEANDLE_PEA_TRANSFORMER_H

#include "llvm/ADT/SmallVector.h"
#include "llvm/IR/PassManager.h"

namespace llvm {

class Instruction;
class DominatorTree;

/// Compute minimal materialize points from all escape points.
/// 
/// Given all escape points (where allocation becomes GlobalEscape),
/// use DominatorTree to filter out dominated points, returning
/// the minimal set of points where allocation must be materialized.
///
/// Example:
/// ```
/// EscapePoints: [A, B, C]
/// DT: A dominates B, B dominates C
/// Result: [A]  // Only A needs materialization
/// ```
///
/// TODO(PEA-Transform): Implement dominator-based filtering
SmallVector<Instruction *> 
computeMinimalMaterializePoints(const SmallVector<Instruction *> &EscapePoints,
                                DominatorTree &DT);

class PEATransformerPass : public PassInfoMixin<PEATransformerPass> {
public:
  PEATransformerPass() {}
  PreservedAnalyses run(Function &F, FunctionAnalysisManager &FAM);
};

} // namespace llvm

#endif // LLVM_TRANSFORMS_JEANDLE_PEA_TRANSFORMER_H
