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
  static constexpr const char *CurrentThread = "current-thread";

  static constexpr const char *StackPointer = "stack-pointer";

  static constexpr const char *HeapBase = "heap-base";

  static constexpr const char *JavaMethodCompilation =
      "java-method-compilation";

  static constexpr const char *DynamicCallPatchSize = "dynamic-call-patch-size";

  static constexpr const char *StaticCallPatchSize = "static-call-patch-size";

  static constexpr const char *JavaKlass = "java-klass";

  static constexpr const char *JavaKlassExact = "java-klass-exact";

  static constexpr const char *InlineScopeID = "inline-scope-id";

  // Set by inclusive loop versioning on the latch of the slow-path clone so the
  // later strip-mining pass skips it instead of trying to version it again.
  static constexpr const char *InclusiveSlowPath = "jeandle.inclusive.slow";

  static constexpr const char *SkipSafepointCoverageVerifier =
      "skip-safepoint-coverage-verifier";
};

enum AddrSpace : unsigned {
  CHeapAddrSpace = 0,
  JavaHeapAddrSpace = 1,
  TLSAddrSpace = 2,
  NarrowOopAddrSpace = 3
};

} // namespace llvm::jeandle

#endif // JEANDLE_METADATA_H
