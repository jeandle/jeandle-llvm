//===- Metadata.h - Jeandle Metadata and Type Utilities -------------------===//
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

#include "llvm/ADT/STLExtras.h"
#include "llvm/IR/DerivedTypes.h"
#include "llvm/IR/Type.h"

namespace llvm::jeandle {

class Metadata {
public:
  static constexpr const char *CurrentThread = "current-thread";

  static constexpr const char *StackPointer = "stack-pointer";

  static constexpr const char *JavaMethodCompilation =
      "java-method-compilation";

  static constexpr const char *JavaKlass = "java-klass";

  static constexpr const char *JavaKlassExact = "java-klass-exact";
};

enum AddrSpace : unsigned {
  CHeapAddrSpace = 0,
  JavaHeapAddrSpace = 1,
  TLSAddrSpace = 2
};

// Refer to similar functions in SafepointIRVerifier.cpp
static bool isJavaHeapPointerType(Type *Ty) {
  if (!Ty || !Ty->isPointerTy())
    return false;
  return dyn_cast<PointerType>(Ty)->getAddressSpace() == JavaHeapAddrSpace;
}

// Refer to similar functions in SafepointIRVerifier.cpp
// Jeandle JDK never generates composite type value, but detection is retained for generality
static bool containsJavaHeapPtrType(Type *Ty) {
  if (isJavaHeapPointerType(Ty))
    return true;
  if (auto *VT = dyn_cast<VectorType>(Ty))
    return isJavaHeapPointerType(VT->getScalarType());
  if (auto *AT = dyn_cast<ArrayType>(Ty))
    return containsJavaHeapPtrType(AT->getElementType());
  if (auto *ST = dyn_cast<StructType>(Ty))
    return llvm::any_of(ST->elements(), containsJavaHeapPtrType);
  return false;
}

} // namespace llvm::jeandle

#endif // JEANDLE_METADATA_H
