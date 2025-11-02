//===- GCStrategy.cpp - Jeandle GC Strategy -------------------------------===//
//
// Copyright (c) 2025, the Jeandle-LLVM Authors. All Rights Reserved.
//
// Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM
// Exceptions. See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#include "llvm/IR/GCStrategy.h"
#include "llvm/IR/DerivedTypes.h"
#include "llvm/IR/Jeandle/GCStrategy.h"
#include "llvm/IR/Jeandle/Metadata.h"

namespace {

class HotspotGC : public llvm::GCStrategy {
public:
  HotspotGC() {
    UseStatepoints = true;
    UseRS4GC = true;
    // These options are all gc.root specific, we specify them so that the
    // gc.root lowering code doesn't run.
    NeededSafePoints = false;
    UsesMetadata = false;
  }

  std::optional<bool> isGCManagedPointer(const llvm::Type *Ty) const override {
    // Method is only valid on pointer typed values.
    const llvm::PointerType *PT = llvm::cast<llvm::PointerType>(Ty);
    return (llvm::jeandle::AddrSpace::JavaHeapAddrSpace ==
            PT->getAddressSpace());
  }
};

} // end anonymous namespace

namespace llvm::jeandle {

static llvm::GCRegistry::Add<HotspotGC> A(JeandleGC, "For Jeandle GC.");

bool isJeandleGC(StringRef Name) { return Name == JeandleGC; }

void linkAllJeandleGCs() {}

} // namespace llvm::jeandle
