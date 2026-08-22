//===- VMConstants.cpp - Jeandle VM layout constants impl --------*- C++
//-*-===//
//
// Copyright (c) 2026, the Jeandle-LLVM Authors. All Rights Reserved.
//
// Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM
// Exceptions. See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
// Implementation of `VMConstants::fromModule` (read patched globals back out
// of the IR Module) and the `classifyType` helper.  See VMConstants.h for the
// delivery model.
//
//===----------------------------------------------------------------------===//

#include "llvm/IR/Jeandle/VMConstants.h"

#include "llvm/ADT/SmallString.h"
#include "llvm/ADT/StringRef.h"
#include "llvm/IR/Constants.h"
#include "llvm/IR/DerivedTypes.h"
#include "llvm/IR/GlobalVariable.h"
#include "llvm/IR/Jeandle/Metadata.h"
#include "llvm/IR/Module.h"
#include "llvm/IR/Type.h"

namespace llvm {
namespace jeandle {

JBasicType VMConstants::classifyType(Type *Ty) {
  if (!Ty)
    return JBasicType::Count;
  if (Ty->isPointerTy()) {
    auto *PT = cast<PointerType>(Ty);
    if (PT->getAddressSpace() == jeandle::AddrSpace::JavaHeapAddrSpace)
      return JBasicType::Object;
    return JBasicType::Count;
  }
  if (Ty->isIntegerTy()) {
    switch (Ty->getIntegerBitWidth()) {
    case 1:
      return JBasicType::Boolean;
    case 8:
      return JBasicType::Byte;
    case 16:
      return JBasicType::Short;
    case 32:
      return JBasicType::Int;
    case 64:
      return JBasicType::Long;
    default:
      return JBasicType::Count;
    }
  }
  if (Ty->isFloatTy())
    return JBasicType::Float;
  if (Ty->isDoubleTy())
    return JBasicType::Double;
  return JBasicType::Count;
}

namespace {

// Read a ConstantInt initializer from a named global in `M`. Returns
// std::nullopt if the global is absent, is still a declaration (no
// initializer), or carries a non-ConstantInt initializer. The HotSpot side
// patches every declaration with a ConstantInt and marks it `Constant +
// PrivateLinkage` before passing the module to LLVM; missing entries are
// expected only in LLVM-side lit/unit tests that never link the template
// module, and the caller falls back to compile-time defaults in that case.
std::optional<int64_t> readGlobalInt(const Module &M, StringRef Name) {
  const GlobalVariable *GV = M.getNamedGlobal(Name);
  if (!GV)
    return std::nullopt;
  if (!GV->hasInitializer())
    return std::nullopt;
  if (const auto *CI = dyn_cast<ConstantInt>(GV->getInitializer()))
    return CI->getSExtValue();
  return std::nullopt;
}

std::optional<bool> readGlobalBool(const Module &M, StringRef Name) {
  if (auto V = readGlobalInt(M, Name))
    return *V != 0;
  return std::nullopt;
}

// Stable lowercase basictype name used in the symbol convention
// "arrayOopDesc.base_offset_in_bytes.<name>" and
// "arrayOopDesc.element_size.<name>". Must match the JDK-side
// RuntimeDefinedJavaOps::define_global_variables declarations and the
// template.ll declarations.
const char *jBasicTypeName(JBasicType Kind) {
  switch (Kind) {
  case JBasicType::Boolean:
    return "boolean";
  case JBasicType::Byte:
    return "byte";
  case JBasicType::Char:
    return "char";
  case JBasicType::Short:
    return "short";
  case JBasicType::Int:
    return "int";
  case JBasicType::Long:
    return "long";
  case JBasicType::Float:
    return "float";
  case JBasicType::Double:
    return "double";
  case JBasicType::Object:
    return "object";
  case JBasicType::Count:
    return nullptr;
  }
  return nullptr;
}

} // namespace

VMConstants VMConstants::fromModule(const Module &M) {
  VMConstants C; // start from compile-time defaults

  if (auto V = readGlobalInt(M, "oopDesc.mark_offset_in_bytes"))
    C.MarkWordOffset = *V;
  if (auto V = readGlobalInt(M, "oopDesc.klass_offset_in_bytes"))
    C.KlassOffset = *V;
  if (auto V = readGlobalInt(M, "markWord.prototype_value"))
    C.DefaultMarkWord = *V;
  if (auto V = readGlobalInt(M, "arrayOopDesc.length_offset_in_bytes"))
    C.ArrayLengthOffset = *V;
  if (auto V = readGlobalInt(M, "instanceOopDesc.base_offset_in_bytes"))
    C.InstanceBaseOffset = *V;

  for (unsigned I = 0; I < (unsigned)JBasicType::Count; ++I) {
    const char *N = jBasicTypeName(static_cast<JBasicType>(I));
    if (!N)
      continue;
    SmallString<64> Buf;
    Buf.append("arrayOopDesc.base_offset_in_bytes.");
    Buf.append(N);
    if (auto V = readGlobalInt(M, Buf))
      C.ArrayBaseOffset[I] = *V;

    Buf.clear();
    Buf.append("arrayOopDesc.element_size.");
    Buf.append(N);
    if (auto V = readGlobalInt(M, Buf))
      C.ElementSize[I] = static_cast<uint64_t>(*V);
  }

  if (auto V = readGlobalBool(M, "VMOptions.UseCompressedClassPointers"))
    C.UseCompressedClassPointers = *V;
  if (auto V = readGlobalBool(M, "VMOptions.UseCompressedOops"))
    C.UseCompressedOops = *V;
  if (auto V = readGlobalInt(M, "VMOptions.ArrayOperationPartialInlineSize"))
    C.ArrayOperationPartialInlineSize = *V;
  if (auto V = readGlobalInt(M, "VMOptions.ArrayCopyLoadStoreMaxElem"))
    C.ArrayCopyLoadStoreMaxElem = *V;

  return C;
}

} // namespace jeandle
} // namespace llvm
