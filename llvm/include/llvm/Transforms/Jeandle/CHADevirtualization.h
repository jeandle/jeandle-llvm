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
//
// This struct has two encodings, distinguished by ConstraintOrHolder bit 0.
//
// MethodHandle intrinsic invoke opt result:
//   ConstraintOrHolder: target method holder with bit 0 set for validation.
//     Clear bit 0 before using it as a Klass pointer.
//   Method: optimized target method, ciMethod*.
//   DeoptReasonOrTargetInfo: packed signature info.
//     Bit 0: target->is_static()
//     Bit 1: target->is_accessor()
//     Bit 2: target->can_be_statically_bound()
//     Bits 3..31: target->signature()->count()
//
// Regular Java invoke opt and MethodHandle _invokebasic intrinsic:
//   ConstraintOrHolder: receiver constraint Klass* required by the optimized
//     target.
//   Method: optimized target method, ciMethod*.
//   DeoptReasonOrTargetInfo: packed info.
//      Bit 0: method->is_static()
//      Bit 1: method->is_accessor()
//      Bits 2..31: Deoptimization::DeoptReason for the uncommon-trap path.
//
// MethodName is method_name_with_signature(Method) in both forms.
struct CHAOptInfo {
  uintptr_t ConstraintOrHolder = 0;
  uintptr_t Method = 0;
  uintptr_t DeoptReasonOrTargetInfo = 0;
  std::string MethodName;

  // Regular invoke view.
  Deoptimization::DeoptReason deoptReason() const {
    assert(!isMethodHandle() && "should be regular invoke");
    return static_cast<Deoptimization::DeoptReason>(DeoptReasonOrTargetInfo >>
                                                    2);
  }

  bool isAccessor() const { return DeoptReasonOrTargetInfo & 2; }

  uintptr_t constraint() const {
    assert(!isMethodHandle() && "should be regular invoke");
    return ConstraintOrHolder;
  }

  // Method handle intrinsic invoke view.
  uintptr_t holder() const {
    assert(isMethodHandle() && "should be method handle intrinsic invoke");
    return ConstraintOrHolder ^ 1;
  }

  bool isStatic() const { return DeoptReasonOrTargetInfo & 1; }

  bool canBeStaticallyBound() const {
    assert(isMethodHandle() && "should be method handle intrinsic invoke");
    return DeoptReasonOrTargetInfo & 4;
  }

  int argsNum() const {
    assert(isMethodHandle() && "should be method handle intrinsic invoke");
    return DeoptReasonOrTargetInfo >> 3;
  }

  static uintptr_t packTargetInfo(bool IsStatic, bool IsAccessor,
                                  bool CanBeStaticallyBound, int ArgsNum) {
    return IsStatic | (IsAccessor << 1) | (CanBeStaticallyBound << 2) |
           (ArgsNum << 3);
  }

  static uintptr_t packDeoptreasonInfo(bool IsStatic, bool IsAccessor,
                                       Deoptimization::DeoptReason Reason) {
    return IsStatic | (IsAccessor << 1) | (Reason << 2);
  }

  static CHAOptInfo decode(const std::string &Encoding) {
    CHAOptInfo Info;
    char Sep;
    if (Encoding.empty())
      return Info;
    std::istringstream Iss(Encoding);
    Iss >> Info.ConstraintOrHolder >> Sep >> Info.Method;
    assert(Sep == '#' && "should be");
    Iss >> Sep >> Info.DeoptReasonOrTargetInfo;
    assert(Sep == '#' && "should be");
    Iss >> Sep >> Info.MethodName;
    assert(Sep == '#' && "should be");
    return Info;
  }

  std::string encode() {
    std::ostringstream Oss;
    Oss << ConstraintOrHolder << '#' << Method << '#' << DeoptReasonOrTargetInfo
        << '#' << MethodName;
    return Oss.str();
  }

private:
  bool isMethodHandle() const { return ConstraintOrHolder & 1; }
};

} // namespace jeandle

class CHADevirtualization : public PassInfoMixin<CHADevirtualization> {
public:
  CHADevirtualization() {}
  PreservedAnalyses run(Function &F, FunctionAnalysisManager &FAM);
};

} // namespace llvm

#endif // LLVM_CHA_DEVIRTUALIZATION_H
