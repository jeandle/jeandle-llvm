//===- JeandleUtils.h - Jeandle common utility definitions ----------------===//
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
#include "llvm/IR/Function.h"
#include "llvm/IR/GlobalVariable.h"
#include "llvm/IR/Jeandle/Attributes.h"
#include "llvm/IR/Jeandle/Metadata.h"
#include "llvm/IR/Module.h"
#include "llvm/IR/Type.h"
#include "llvm/Support/Debug.h"
#include "llvm/Support/ErrorHandling.h"
#include "llvm/Support/raw_ostream.h"

#include <optional>
#include <string>

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
  T_VOID = 14,
  T_ADDRESS = 15,
  T_NARROWOOP = 16,
  T_METADATA = 17,
  T_NARROWKLASS = 18,
  T_CONFLICT = 19,
  T_ILLEGAL = 99
};

// Mirror of jvm isDoubleWordType function.
// Return true if BasicTy is a double-word type.
inline bool isDoubleWordType(HotspotBasicType BasicTy) {
  return (BasicTy == T_DOUBLE || BasicTy == T_LONG);
}

// Convert a Java type to computational type
// Reference:
// https://docs.oracle.com/javase/specs/jvms/se21/html/jvms-2.html#jvms-2.11.1-320
inline HotspotBasicType actual2computational(HotspotBasicType BT) {
  switch (BT) {
  case T_BYTE:
  case T_CHAR:
  case T_SHORT:
  case T_BOOLEAN:
  case T_INT:
    return T_INT;
  case T_VOID:
  case T_LONG:
  case T_FLOAT:
  case T_DOUBLE:
    return BT;
  case T_ARRAY:
  case T_OBJECT:
    return T_OBJECT;
  case T_ADDRESS:
    return T_ADDRESS;
  case T_NARROWOOP:
    return T_NARROWOOP;
  case T_NARROWKLASS:
    return T_NARROWKLASS;
  default:
    llvm_unreachable("Should not reach here");
  }
}

// Transform llvm::Type to HotspotBasicType.
// Note that the return value is the computational type.
// A single LLVM Type may correspond to multiple actual Hotspot BasicTypes.
// See JeandleType::actual2computational and JeandleType::java2llvm in
// Jeandle-JDK.
inline HotspotBasicType LLVM2JavaComputational(Type *Ty) {
  if (Ty->isPointerTy()) {
    if (Ty->getPointerAddressSpace() == jeandle::AddrSpace::JavaHeapAddrSpace)
      return T_OBJECT;
    if (Ty->getPointerAddressSpace() == jeandle::AddrSpace::NarrowOopAddrSpace)
      return T_NARROWOOP;
  }
  if (Ty->isIntegerTy(32))
    return jeandle::T_INT;
  if (Ty->isIntegerTy(64))
    return jeandle::T_LONG;
  if (Ty->isFloatTy())
    return jeandle::T_FLOAT;
  if (Ty->isDoubleTy())
    return jeandle::T_DOUBLE;
  return T_ILLEGAL;
}

// Transform HotspotBasicType to llvm::Type.
inline Type *java2llvm(HotspotBasicType JavaType, LLVMContext &Context) {
  // Make sure java2llvm(type) == java2llvm(actual2computational(type))
  HotspotBasicType ComputationalType = actual2computational(JavaType);
  switch (ComputationalType) {
  case T_BOOLEAN:
  case T_CHAR:
  case T_BYTE:
  case T_SHORT:
  case T_INT:
    return llvm::Type::getInt32Ty(Context);
  case T_FLOAT:
    return llvm::Type::getFloatTy(Context);
  case T_DOUBLE:
    return llvm::Type::getDoubleTy(Context);
  case T_LONG:
    return llvm::Type::getInt64Ty(Context);
  case T_OBJECT:
    return llvm::PointerType::get(Context,
                                  llvm::jeandle::AddrSpace::JavaHeapAddrSpace);
  case T_ARRAY:
    return llvm::PointerType::get(Context,
                                  llvm::jeandle::AddrSpace::JavaHeapAddrSpace);
  case T_VOID:
    return llvm::Type::getVoidTy(Context);
  case T_ADDRESS:
    return llvm::PointerType::get(Context,
                                  llvm::jeandle::AddrSpace::CHeapAddrSpace);
  case T_NARROWOOP:
    return llvm::PointerType::get(Context,
                                  llvm::jeandle::AddrSpace::NarrowOopAddrSpace);
  case T_NARROWKLASS:
    return llvm::Type::getInt32Ty(Context);
  case T_METADATA:
  case T_CONFLICT:
  case T_ILLEGAL:
    DEBUG_WITH_TYPE("jeandle-utils",
                    dbgs() << "Unsupported type: " << JavaType << "\n");
    return nullptr;
  }
  DEBUG_WITH_TYPE("jeandle-utils",
                  dbgs() << "Unsupported type: " << JavaType << "\n");
  return nullptr;
}

/// Returns true if \p Ty is a pointer in the Java heap address space,
/// i.e., it represents a uncompressed Java object reference (oop).
inline bool isWideOopType(Type *Ty) {
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
  return isWideOopType(Ty) || isNarrowOopType(Ty);
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

/// Returns true if \p F carries the "java-method" attribute — i.e. it
/// represents a Java method (the compiled root method, or an inlined callee
/// body / declaration).
inline bool isJeandleJavaMethod(const Function &F) {
  return F.hasFnAttribute(jeandle::Attribute::JavaMethod);
}

/// Returns true if \p F is the root Java method being compiled: it carries the
/// "java-method" attribute and has a real body (not a declaration and not
/// available_externally). Used to scope intra-procedural passes to the single
/// compiled method — only this function is ever emitted.
inline bool isRootJavaMethodFunction(const Function &F) {
  return isJeandleJavaMethod(F) && !F.isDeclaration() &&
         !F.hasAvailableExternallyLinkage();
}

/// Finds the root Java method in \p M (see isRootJavaMethodFunction). There is
/// expected to be at most one such function per module; finding more than one
/// is a fatal error.
inline Function *getRootJavaMethodFunction(Module &M) {
  Function *RootFunction = nullptr;
  for (Function &F : M) {
    if (!isRootJavaMethodFunction(F))
      continue;
    if (!RootFunction) {
      RootFunction = &F;
    } else {
      std::string Message;
      raw_string_ostream OS(Message);
      OS << "Jeandle: expected at most one root Java method function, "
         << "found '" << RootFunction->getName() << "' and '" << F.getName()
         << "'";
      OS.flush();
      report_fatal_error(StringRef(Message));
    }
  }
  return RootFunction;
}
// CHADestKind that represents the destination type of a call site.
enum CHADestKind { StaticCall, VirtualCall, OptVirtualCall, Illegal };

} // namespace llvm::jeandle

#endif // JEANDLE_UTILS_HPP
