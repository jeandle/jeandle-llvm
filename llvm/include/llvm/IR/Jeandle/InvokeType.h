//===- InvokeType.h - Jeandle InvokeType ----------------------------------===//
//
// Copyright (c) 2025, the Jeandle-LLVM Authors. All Rights Reserved.
//
// Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM
// Exceptions. See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#include "llvm/ADT/StringRef.h"
#include "llvm/ADT/StringSwitch.h"

#ifndef JEANDLE_INVOKE_TYPE_H
#define JEANDLE_INVOKE_TYPE_H

namespace llvm::jeandle {

enum InvokeType {
  InvokeVirtual,
  InvokeSpecial,
  InvokeStatic,
  InvokeInterface,
  InvokeDynamic,
  ILLEGAL
};

inline InvokeType getInvokeType(StringRef &Invoke) {
  return StringSwitch<InvokeType>(Invoke)
      .Case("invokevirtual", InvokeVirtual)
      .Case("invokespecial", InvokeSpecial)
      .Case("invokestatic", InvokeStatic)
      .Case("invokeinterface", InvokeInterface)
      .Case("invokedynamic", InvokeDynamic)
      .Default(ILLEGAL);
}

} // namespace llvm::jeandle

#endif
