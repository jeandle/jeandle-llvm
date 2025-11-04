//===- GCStrategy.h - Jeandle GC Strategy ---------------------------------===//
//
// Copyright (c) 2025, the Jeandle-LLVM Authors. All Rights Reserved.
//
// Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM
// Exceptions. See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#ifndef JEANDLE_METADATA_H
#define JEANDLE_METADATA_H

namespace llvm::jeandle {

class Metadata {
public:
  static constexpr const char *CurrentThread = "current_thread";

  static constexpr const char *StackPointer = "stack_pointer";

  static constexpr const char *JavaMethodCompilation =
      "java_method_compilation";
};

enum AddrSpace : unsigned {
  CHeapAddrSpace = 0,
  JavaHeapAddrSpace = 1,
  TLSAddrSpace = 2
};

} // namespace llvm::jeandle

#endif // JEANDLE_METADATA_H
