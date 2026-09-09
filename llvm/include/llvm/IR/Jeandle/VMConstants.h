//===- VMConstants.h - Jeandle VM layout constants --------------*- C++ -*-===//
//
// Copyright (c) 2026, the Jeandle-LLVM Authors. All Rights Reserved.
//
// Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM
// Exceptions. See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
// HotSpot heap-layout constants the LLVM-side passes (currently the partial
// escape analyzer) need to reason about Java objects and arrays.
//
// Delivery model (runtime-defined globals)
// ----------------------------------------
// Each constant is declared in the Jeandle template module
// (`jeandle-jdk/src/hotspot/share/jeandle/templatemodule/template.ll`) as an
// `external global` with a stable symbol name. At compiler init time HotSpot
// runs `RuntimeDefinedJavaOps::define_global_variables`
// (jeandleRuntimeDefinedJavaOps.cpp) which patches every declaration with the
// real `arrayOopDesc::base_offset_in_bytes(T_*)` / `type2aelembytes(T_*)` /
// `oopDesc::*_offset_in_bytes()` value, then marks it `Constant` +
// `PrivateLinkage` so InstCombine/GVN can fold the `load i32, ptr @<name>` to
// the literal value.
//
// LLVM-side analyses do NOT use a process-global singleton. They instantiate a
// `VMConstants` from the IR Module being analyzed via `fromModule(M)`. Any
// field whose corresponding global is absent from the module, or whose
// initializer is not a ConstantInt, keeps the compile-time default below. The
// defaults match a typical 64-bit build with compressed klass pointers, which
// is what every in-tree lit test under `llvm/test/Jeandle/` already expects
// (those tests run `opt` directly and never link the template module).
//
// Adding a new constant
// ---------------------
// 1. Add a `external global iN @<symbol> = external global iN` line to
//    template.ll.
// 2. Add a matching `define_global("<symbol>", iN_type, <runtime expr>)` line
//    to `RuntimeDefinedJavaOps::define_global_variables`.
// 3. Add a field + default to `struct VMConstants` below, populate it in
//    `VMConstants::fromModule`, and expose it via a convenience accessor.
// 4. Read the value from the analyzer via `VMConstants::fromModule(M)`.
//
// Why not just inline `load i32, ptr @<symbol>` in the analyzer?
//   Some uses (e.g. populating `VirtualObject::ArrayBaseOffset`) are not
//   themselves emitted as IR — the analyzer reasons about the constant
//   numerically. `fromModule` reads the patched initializer back out and
//   surfaces it as a plain integer.
//
//===----------------------------------------------------------------------===//

#ifndef LLVM_IR_JEANDLE_VMCONSTANTS_H
#define LLVM_IR_JEANDLE_VMCONSTANTS_H

#include <cstdint>

namespace llvm {

class Module;
class Type;

namespace jeandle {

// BasicType IDs mirroring HotSpot's enum BasicType in oops/typeArrayKlass.hpp.
// Used as index into per-element-type tables below.
enum class JBasicType : uint8_t {
  Boolean = 0,
  Byte = 1,
  Char = 2,
  Short = 3,
  Int = 4,
  Long = 5,
  Float = 6,
  Double = 7,
  Object = 8,
  Count = 9
};

struct VMConstants {
  // oopDesc layout (in bytes).
  int64_t MarkWordOffset = 0;
  int64_t KlassOffset = 8; // 8 with compressed klass; HotSpot may override.
  int64_t DefaultMarkWord =
      1; // markWord::prototype() — biased lock bit cleared.

  // arrayOopDesc layout.
  int64_t ArrayLengthOffset = 12; // 12 with compressed klass; 16 without.

  // instanceOopDesc layout.  The opt-only lit tests do not link the runtime
  // VMConstants globals, so keep the fallback permissive; JVM compilations
  // override this with the real first Java-field offset from HotSpot.
  int64_t InstanceBaseOffset = 0;

  // Per-element-type base offsets. Indexed by JBasicType.
  int64_t ArrayBaseOffset[(unsigned)JBasicType::Count] = {
      /*Boolean*/ 16, /*Byte*/ 16, /*Char*/ 16,  /*Short*/ 16,
      /*Int*/ 16,     /*Long*/ 16, /*Float*/ 16, /*Double*/ 16,
      /*Object*/ 16,
  };

  // Per-element size in bytes. Indexed by JBasicType.
  uint64_t ElementSize[(unsigned)JBasicType::Count] = {
      /*Boolean*/ 1, /*Byte*/ 1, /*Char*/ 2,  /*Short*/ 2,
      /*Int*/ 4,     /*Long*/ 8, /*Float*/ 4, /*Double*/ 8,
      /*Object*/ 4, // compressed oop default
  };

  bool UseCompressedClassPointers = true;
  bool UseCompressedOops = true;

  // Arraycopy optimization thresholds supplied by HotSpot VM flags.
  int64_t ArrayOperationPartialInlineSize = 0;
  int64_t ArrayCopyLoadStoreMaxElem = 8;

  // Convenience accessors.
  int64_t arrayLengthOffset() const { return ArrayLengthOffset; }
  int64_t klassOffset() const { return KlassOffset; }
  int64_t markWordOffset() const { return MarkWordOffset; }
  int64_t defaultMarkWord() const { return DefaultMarkWord; }
  int64_t instanceBaseOffset() const { return InstanceBaseOffset; }
  int64_t arrayOperationPartialInlineSize() const {
    return ArrayOperationPartialInlineSize;
  }
  int64_t arrayCopyLoadStoreMaxElem() const {
    return ArrayCopyLoadStoreMaxElem;
  }

  // Returns the array base offset for an element type. Returns -1 if Ty is not
  // a recognised Jeandle element type.
  int64_t arrayBaseOffsetFor(JBasicType Kind) const {
    return ArrayBaseOffset[(unsigned)Kind];
  }
  uint64_t elementSizeFor(JBasicType Kind) const {
    return ElementSize[(unsigned)Kind];
  }

  // Best-effort mapping from an LLVM Type * to JBasicType. nullptr-safe.
  // Returns JBasicType::Count if Ty does not map to a Java basic type we model.
  static JBasicType classifyType(Type *Ty);

  // Populate a VMConstants by looking up the runtime-defined globals in `M`.
  // See header banner for the delivery model. Fields whose corresponding
  // global is absent or whose initializer is not a ConstantInt keep the
  // compile-time default declared above.
  static VMConstants fromModule(const Module &M);
};

} // namespace jeandle
} // namespace llvm

#endif
