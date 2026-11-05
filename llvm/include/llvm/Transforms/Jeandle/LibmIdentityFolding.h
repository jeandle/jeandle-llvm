//===- LibmIdentityFolding.h - Fold exact Math.pow runtime identities ----*- C++
//-*-===//
//
// Copyright (c) 2026, The Jeandle-LLVM Authors. All Rights Reserved.
//
// Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM
// Exceptions. See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//
//
// Folds the exact constant-exponent identities of the HotSpot runtime dpow
// call that the Jeandle frontend emits for Math.pow while
// JeandleUseHotspotIntrinsics is on (StubRoutines::dpow where the platform
// generated a stub, else SharedRuntime::dpow):
//
//   dpow(x, 2.0)   -> x * x
//   dpow(x, +-0.0) -> 1.0
//
// Both identities are bit-exact against both runtime entries on every
// input, NaN payloads and signaling-NaN quieting included: the fdlibm port
// returns x*x for y==2 before any range reduction and tests (iy|ly)==0
// before its NaN check, and the x86 libm stub multiplies at entry. All
// other exponents are left alone -- see LibmIdentityFolding.cpp for the
// excluded cases (y==1.0 in particular is NOT bit-exact for a signaling-NaN
// base).
//
// The runtime call is opaque to LLVM's libcall machinery, so without this
// pass the identities are unreachable in the default configuration. The
// pass deliberately does NOT look through selects/PHIs: exponents that only
// later passes can prove constant (inlining, SCCP, instcombine) are handled
// by running the pass after the revealing passes in the pipeline, so the
// frontend itself needs no constant-exponent checks.
//
//===----------------------------------------------------------------------===//

#ifndef LLVM_TRANSFORMS_JEANDLE_LIBMIDENTITYFOLDING_H
#define LLVM_TRANSFORMS_JEANDLE_LIBMIDENTITYFOLDING_H

#include "llvm/IR/PassManager.h"

namespace llvm {

class LibmIdentityFolding : public PassInfoMixin<LibmIdentityFolding> {
public:
  LibmIdentityFolding() = default;
  PreservedAnalyses run(Function &F, FunctionAnalysisManager &FAM);
};

} // namespace llvm

#endif // LLVM_TRANSFORMS_JEANDLE_LIBMIDENTITYFOLDING_H
