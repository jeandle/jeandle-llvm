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

// RecoverTypeInfo re-attaches !java-klass / !java-klass-exact metadata to
// oop-typed field loads that lost it (typically stripped by load CSE in
// EarlyCSE / InstCombine, which only preserve LLVM's built-in metadata kinds).
//
// For each such load the pass recomputes the field's declared type from the
// base pointer's Java klass and the load's constant byte offset, querying the
// VM via GetFieldType. It is a monotone fixpoint over a three-state lattice
// (Top / Known{klass,exact} / Bottom) so that:
//   * a base pointer that is itself a recovered field load resolves through
//     arbitrary-length field chains;
//   * PHI / select merges widen to the lowest common ancestor; and
//   * loop-carried PHIs (including self-referential and mutually-recursive
//     back-edges) converge without explicit cycle detection, since Top is the
//     meet identity and Bottom is terminal.
//
// The pass attaches metadata only; it preserves CFGAnalyses and never touches
// loads that already carry !java-klass (idempotent).
class RecoverTypeInfo : public PassInfoMixin<RecoverTypeInfo> {
public:
  PreservedAnalyses run(Function &F, FunctionAnalysisManager &FAM);
};

} // namespace llvm

#endif // LLVM_RECOVER_TYPE_INFO_H
