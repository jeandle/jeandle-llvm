//===- GCStrategy.h - Jeandle GC Strategy ---------------------------------===//
//
// Copyright (c) 2025, the Jeandle-LLVM Authors. All Rights Reserved.
//
// Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM
// Exceptions. See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#ifndef JEANDLE_GCSTRATEGY_H
#define JEANDLE_GCSTRATEGY_H

#include "llvm/ADT/StringRef.h"

namespace llvm::jeandle {

constexpr const char *JeandleGC = "hotspotgc";

bool isJeandleGC(StringRef Name);

void linkAllJeandleGCs();

} // namespace llvm::jeandle

#endif // JEANDLE_GCSTRATEGY_H
