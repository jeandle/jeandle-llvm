//===- Attributes.h - Jeandle Attributes ----------------------------------===//
//
// Copyright (c) 2025, the Jeandle-LLVM Authors. All Rights Reserved.
//
// Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM
// Exceptions. See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#ifndef JEANDLE_ATTRIBUTE_H
#define JEANDLE_ATTRIBUTE_H

#include "llvm/IR/Attributes.h"

namespace llvm::jeandle {

class Attribute {
public:
  static constexpr const char *UseCompressedOops = "use-compressed-oops";

  static constexpr const char *StatepointID = "statepoint-id";

  static constexpr const char *StatepointNumPatchBytes =
      "statepoint-num-patch-bytes";

  static constexpr const char *LowerPhase = "lower-phase";
};

} // namespace llvm::jeandle

#endif // JEANDLE_ATTRIBUTE_H
