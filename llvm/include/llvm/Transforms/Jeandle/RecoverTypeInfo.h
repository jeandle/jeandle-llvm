//===- RecoverTypeInfo.h - Recover dropped !java-klass metadata -*- C++ -*-===//
//
// Copyright (c) 2026, the Jeandle-LLVM Authors. All Rights Reserved.
//
// Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM
// Exceptions. See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#ifndef LLVM_RECOVER_TYPE_INFO_H
#define LLVM_RECOVER_TYPE_INFO_H

#include "llvm/IR/PassManager.h"

namespace llvm {

// RecoverTypeInfo attaches !java-klass / !java-klass-exact metadata to
// oop-typed loads whose result klass can be proven: field loads that lost
// their metadata (typically stripped by load CSE in EarlyCSE / InstCombine,
// which only preserve LLVM's built-in metadata kinds) and array element loads
// (which the frontend deliberately leaves untyped).
//
// For each such load the pass derives the result klass from the klass of the
// object being loaded from: ArrayElementKlass for an object-array base, or
// GetFieldType(baseKlass, offset) for an instance base at a constant offset.
// The base klass is the intersection of two sources:
//   * a fixpoint over a three-state lattice (Top / Known{klass,exact} /
//     Bottom) seeded from java-klass attributes, surviving metadata and
//     constant oop handles, so that:
//       - a base that is itself a recovered load resolves through
//         arbitrary-length chains;
//       - PHI / select merges widen to the lowest common ancestor; and
//       - loop-carried PHIs (including self-referential and
//         mutually-recursive back-edges) converge without explicit cycle
//         detection, since Top is the meet identity and Bottom is terminal.
//     Transitions are descents except for one-shot "rescues", where a value
//     ascends once from Top/Bottom to a Known that instanceof-derived facts
//     prove (see the lattice comment in the .cpp); trajectories are bounded
//     by klass-chain depth and the fixpoint still converges;
//   * a context-sensitive getJavaType query on the base at the load's
//     position, which additionally sharpens the type through dominating
//     jeandle.check_instanceof checks. The query is constant during the
//     fixpoint (the pass mutates no IR until the emit phase) and is cached
//     per load.
//
// The pass attaches metadata only; it preserves CFGAnalyses and never touches
// loads that already carry !java-klass (idempotent).
class RecoverTypeInfo : public PassInfoMixin<RecoverTypeInfo> {
public:
  PreservedAnalyses run(Function &F, FunctionAnalysisManager &FAM);
};

} // namespace llvm

#endif // LLVM_RECOVER_TYPE_INFO_H
