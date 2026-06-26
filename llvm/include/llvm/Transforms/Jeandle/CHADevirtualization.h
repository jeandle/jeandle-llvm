//===- CHADevirtualization.h - Jeandle CHA devirtualization --------------===//
//
// Copyright (c) 2026, the Jeandle-LLVM Authors. All Rights Reserved.
//
// Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM
// Exceptions. See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#ifndef LLVM_CHA_DEVIRTUALIZATION_H
#define LLVM_CHA_DEVIRTUALIZATION_H

#include "llvm/IR/Jeandle/Deoptimization.h"
#include "llvm/IR/PassManager.h"

#include <sstream>

namespace llvm {

namespace jeandle {

// CHA optimization info for devirtualization update IR.
// Constraint: The receiver constraint, Klass*.
// Method: The optimized target method, ciMethod*.
// DeoptReason: The deoptimization reason, Deoptimization::DeoptReason.
// MethodName: The optimized target method name,
//      equals to method_name_with_signature(Method), std::string.
struct CHAOptInfo {

  uintptr_t Constraint = 0;
  uintptr_t Method = 0;
  Deoptimization::DeoptReason DeoptReason;
  std::string MethodName;

  static CHAOptInfo decode(const std::string &Encoding) {
    CHAOptInfo Info;
    int DeoptReasonVal;
    char Sep;
    if (Encoding.empty())
      return Info;
    std::istringstream Iss(Encoding);
    Iss >> Info.Constraint >> Sep >> Info.Method;
    assert(Sep == '#' && "should be");
    Iss >> Sep >> DeoptReasonVal;
    assert(Sep == '#' && "should be");
    assert(DeoptReasonVal > 0 &&
           DeoptReasonVal < Deoptimization::Reason_LIMIT && "should be");
    Info.DeoptReason = static_cast<Deoptimization::DeoptReason>(DeoptReasonVal);
    Iss >> Sep >> Info.MethodName;
    assert(Sep == '#' && "should be");
    return Info;
  }

  std::string encode() {
    std::ostringstream Oss;
    Oss << Constraint << '#' << Method << '#' << static_cast<int>(DeoptReason)
        << '#' << MethodName;
    return Oss.str();
  }
};

} // namespace jeandle

class CHADevirtualization : public PassInfoMixin<CHADevirtualization> {
public:
  CHADevirtualization() {}
  PreservedAnalyses run(Function &F, FunctionAnalysisManager &FAM);

private:
  int PatchSize = 0;
};

} // namespace llvm

#endif // LLVM_CHA_DEVIRTUALIZATION_H
