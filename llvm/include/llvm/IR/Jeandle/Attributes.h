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
  /// Function attributes attached to Jeandle-compiled functions.
  static constexpr const char *UseCompressedOops = "use-compressed-oops";

  static constexpr const char *LowerPhase = "lower-phase";

  static constexpr const char *JavaMethod = "java-method";

  static constexpr const char *JavaAccessorMethod = "java-accessor-method";

  /// Java type attributes attached to function parameters, function returns,
  /// and call/invoke returns.
  static constexpr const char *JavaKlass = "java-klass";

  static constexpr const char *JavaKlassExact = "java-klass-exact";

  /// Call-site attributes attached to CallBase instructions.
  ///
  /// Java bytecode invokes are emitted as InvokeInsts, while VM calls may use
  /// CallInsts. Both are represented by CallBase.
  static constexpr const char *StatepointID = "statepoint-id";

  static constexpr const char *StatepointNumPatchBytes =
      "statepoint-num-patch-bytes";

  /// Call-site attributes attached to java call(InvokeInsts).
  static constexpr const char *Bytecode = "bytecode";

  static constexpr const char *DeclaredHolder = "declared-holder";

  static constexpr const char *MhIntrinsicName = "mh-intrinsic-name";

  static constexpr const char *MonomorphicTarget = "monomorphic-target";
};

} // namespace llvm::jeandle

#endif // JEANDLE_ATTRIBUTE_H
