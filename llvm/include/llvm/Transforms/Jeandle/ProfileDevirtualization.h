//===- ProfileDevirtualization.h - Jeandle profile devirtualization ------===//
//
// Copyright (c) 2026, the Jeandle-LLVM Authors. All Rights Reserved.
//
// Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM
// Exceptions. See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#ifndef LLVM_TRANSFORMS_JEANDLE_PROFILEDEVIRTUALIZATION_H
#define LLVM_TRANSFORMS_JEANDLE_PROFILEDEVIRTUALIZATION_H

#include "llvm/IR/Jeandle/Deoptimization.h"
#include "llvm/IR/Jeandle/VMCallback.h"
#include "llvm/IR/PassManager.h"

#include <cstdint>
#include <string>
#include <utility>

namespace llvm {

namespace jeandle {

// Profile-guided devirtualization information returned by the VM. The callback
// transports this as a tuple for record/replay; the pass immediately wraps the
// tuple in this type, as CHADevirtualization does with CHAOptInfo.
struct ProfileDevirtualizationTargetInfo {
  uintptr_t ReceiverKlass = 0;
  uintptr_t Method = 0;
  int64_t Count = 0;
  std::string MethodName;

  ProfileDevirtualizationTargetInfo() = default;

  explicit ProfileDevirtualizationTargetInfo(
      ProfileDevirtualizationTargetResult Result)
      : ReceiverKlass(std::get<0>(Result)), Method(std::get<1>(Result)),
        Count(std::get<2>(Result)), MethodName(std::move(std::get<3>(Result))) {
  }

  bool isPresent() const { return ReceiverKlass != 0; }
  bool isEmpty() const {
    return ReceiverKlass == 0 && Method == 0 && Count == 0 &&
           MethodName.empty();
  }
  bool isValid() const {
    return isPresent() && Method != 0 && Count > 0 && !MethodName.empty();
  }
};

struct ProfileDevirtualizationInfo {
  ProfileDevirtualizationTargetInfo Target;
  int64_t TotalCount = 0;
  uintptr_t DeoptInfo = 0;
  bool DeoptimizeOnMiss = false;
  ProfileDevirtualizationTargetInfo Target2;

  explicit ProfileDevirtualizationInfo(ProfileDevirtualizationResult Result)
      : Target(std::move(std::get<0>(Result))), TotalCount(std::get<1>(Result)),
        DeoptInfo(std::get<2>(Result)), DeoptimizeOnMiss(std::get<3>(Result)),
        Target2(std::move(std::get<4>(Result))) {}

  Deoptimization::DeoptReason deoptReason() const {
    return static_cast<Deoptimization::DeoptReason>(DeoptInfo >> 2);
  }

  bool isAccessor() const { return DeoptInfo & 1; }
  bool isAccessor2() const { return DeoptInfo & 2; }
  bool isBimorphic() const { return Target2.isPresent(); }

  bool isValid() const {
    if (!Target.isValid() || TotalCount <= 0 || Target.Count > TotalCount)
      return false;
    return isBimorphic()
               ? Target2.isValid() && Target2.Count <= TotalCount - Target.Count
               : Target2.isEmpty();
  }

  static uintptr_t packDeoptInfo(bool IsAccessor, bool IsAccessor2,
                                 Deoptimization::DeoptReason Reason) {
    return IsAccessor | (IsAccessor2 << 1) | (Reason << 2);
  }
};

} // namespace jeandle

/// Uses VM-owned receiver profiles to guard Java virtual calls and replace
/// their hot paths with direct optimized-virtual calls.
class ProfileDevirtualization : public PassInfoMixin<ProfileDevirtualization> {
public:
  PreservedAnalyses run(Function &F, FunctionAnalysisManager &FAM);
};

} // namespace llvm

#endif // LLVM_TRANSFORMS_JEANDLE_PROFILEDEVIRTUALIZATION_H
