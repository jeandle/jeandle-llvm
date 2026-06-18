//===- JeandleUtils.hpp - Jeandle common utility definitions --------------===//
//
// Copyright (c) 2026, the Jeandle-LLVM Authors. All Rights Reserved.
//
// Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM
// Exceptions. See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#ifndef JEANDLE_UTILS_HPP
#define JEANDLE_UTILS_HPP

#include "llvm/ADT/StringRef.h"
#include "llvm/IR/GlobalVariable.h"
#include "llvm/IR/Jeandle/Metadata.h"
#include "llvm/IR/Type.h"

#include <optional>

namespace llvm::jeandle {

/// Basic types used by HotSpot JVM, mirroring HotSpot's BasicType enum.
/// The numeric values must match the HotSpot definitions exactly.
enum HotspotBasicType {
  T_BOOLEAN = 4,
  T_CHAR = 5,
  T_FLOAT = 6,
  T_DOUBLE = 7,
  T_BYTE = 8,
  T_SHORT = 9,
  T_INT = 10,
  T_LONG = 11,
  T_OBJECT = 12,
  T_ARRAY = 13,
};

/// Returns true if \p Ty is a pointer in the Java heap address space,
/// i.e., it represents a uncompressed Java object reference (oop).
inline bool isOopType(Type *Ty) {
  auto *PT = dyn_cast<PointerType>(Ty);
  return PT && PT->getAddressSpace() == jeandle::AddrSpace::JavaHeapAddrSpace;
}

/// Returns true if \p Ty is a pointer in the narrow oop address space,
/// i.e., it represents an compressed Java object reference.
inline bool isNarrowOopType(Type *Ty) {
  auto *PT = dyn_cast<PointerType>(Ty);
  return PT && PT->getAddressSpace() == jeandle::AddrSpace::NarrowOopAddrSpace;
}

/// Returns true for either uncompressed or compressed oop values.
inline bool isJavaOopType(Type *Ty) {
  return isOopType(Ty) || isNarrowOopType(Ty);
}

/// Constant oop handle naming convention.
///
/// The frontend (and ConstantFieldFolding) represent a compile-time-known
/// Java object reference as an external global whose name follows one of:
///   "oop_handle_<id>"          — alias form
///   "oop_handle_<klass>_<id>"  — descriptive form
/// Whatever follows the LAST '_' is the decimal oop id. Any name that does
/// not end in a decimal segment is rejected.
inline bool isOopHandleName(StringRef Name) {
  return Name.starts_with("oop_handle_");
}

/// Parse the oop id from an oop_handle_* global name. Returns std::nullopt if
/// \p Name is not an oop handle name or its trailing segment is not a decimal
/// integer.
inline std::optional<int> parseOopHandleId(StringRef Name) {
  if (!isOopHandleName(Name))
    return std::nullopt;

  StringRef Rest = Name.substr(strlen("oop_handle_"));
  size_t Pos = Rest.rfind('_');
  StringRef IdText = Pos == StringRef::npos ? Rest : Rest.substr(Pos + 1);

  int Id = 0;
  if (IdText.empty() || IdText.getAsInteger(10, Id))
    return std::nullopt;
  return Id;
}

/// If \p V (after stripping pointer casts) is an oop_handle_* global, return
/// its oop id; otherwise std::nullopt.
inline std::optional<int> getOopHandleId(Value *V) {
  auto *GV = dyn_cast<GlobalVariable>(V->stripPointerCasts());
  if (!GV)
    return std::nullopt;
  return parseOopHandleId(GV->getName());
}

} // namespace llvm::jeandle

#endif // JEANDLE_UTILS_HPP
