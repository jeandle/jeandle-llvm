//===- RepeatedConstantFolding.h - Iterate CFF with simplification -*- C++
//-*-===//
//
// Copyright (c) 2026, the Jeandle-LLVM Authors. All Rights Reserved.
//
// Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM
// Exceptions. See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#ifndef LLVM_REPEATED_CONSTANT_FOLDING_H
#define LLVM_REPEATED_CONSTANT_FOLDING_H

#include "llvm/IR/PassManager.h"

namespace llvm {

// Run ConstantFieldFolding to fixed-point, interleaving SCCP and SimplifyCFG
// so that branches turned constant by a fold are eliminated before the next
// fold round. This unlocks PHI nodes that the lattice in CFF would otherwise
// pin to Bottom because of an incoming value on a since-dead path.
class RepeatedConstantFolding : public PassInfoMixin<RepeatedConstantFolding> {
public:
  PreservedAnalyses run(Function &F, FunctionAnalysisManager &FAM);
};

} // namespace llvm

#endif // LLVM_REPEATED_CONSTANT_FOLDING_H
