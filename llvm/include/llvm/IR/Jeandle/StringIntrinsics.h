//===- StringIntrinsics.h - Jeandle string operation ABI -------*- C++ -*-===//
//
// Copyright (c) 2026, the Jeandle-LLVM Authors. All Rights Reserved.
// Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM
// Exceptions. See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#ifndef LLVM_IR_JEANDLE_STRINGINTRINSICS_H
#define LLVM_IR_JEANDLE_STRINGINTRINSICS_H

#include "llvm/IR/Constants.h"
#include "llvm/IR/Instructions.h"
#include <optional>

namespace llvm::jeandle {

enum class StringIntrinsicKind {
  Equals,
  Compare,
  IndexOf,
  IndexOfChar,
  CopyUTF16,
  Compress,
  Inflate
};

// The exact frontend ABI. Counts and positions are logical characters except
// Equals, whose count is bytes. Encoding bit 0/1 selects left/right UTF16.
struct StringIntrinsic {
  StringIntrinsicKind Kind;
  unsigned Encoding = 0;
  bool Layout = false;
  bool leftUTF16() const { return Encoding & 1; }
  bool rightUTF16() const { return Encoding & 2; }
  bool isConversion() const {
    return Kind == StringIntrinsicKind::CopyUTF16 ||
           Kind == StringIntrinsicKind::Compress ||
           Kind == StringIntrinsicKind::Inflate;
  }
};

inline std::optional<StringIntrinsic>
decodeStringIntrinsic(const CallBase &CB) {
  const Function *F = CB.getCalledFunction();
  if (!F || CB.getFunctionType() != F->getFunctionType() ||
      CB.getFunctionType()->isVarArg() || isa<CallBrInst>(CB))
    return std::nullopt;
  StringIntrinsic Op;
  StringRef N = F->getName();
  if (N == "jeandle.string_equals")
    Op.Kind = StringIntrinsicKind::Equals;
  else if (N == "jeandle.string_compare")
    Op.Kind = StringIntrinsicKind::Compare;
  else if (N == "jeandle.string_indexof")
    Op.Kind = StringIntrinsicKind::IndexOf;
  else if (N == "jeandle.string_indexof_char")
    Op.Kind = StringIntrinsicKind::IndexOfChar;
  else if (N == "jeandle.string_copy_utf16")
    Op.Kind = StringIntrinsicKind::CopyUTF16;
  else if (N == "jeandle.string_compress")
    Op.Kind = StringIntrinsicKind::Compress;
  else if (N == "jeandle.string_inflate")
    Op.Kind = StringIntrinsicKind::Inflate;
  else
    return std::nullopt;
  bool Equals = Op.Kind == StringIntrinsicKind::Equals;
  bool Compare = Op.Kind == StringIntrinsicKind::Compare;
  bool Char = Op.Kind == StringIntrinsicKind::IndexOfChar;
  unsigned Arity = Equals ? 3 : (Compare || Char) ? 5 : 6;
  if (CB.arg_size() != Arity)
    return std::nullopt;
  bool Void = Op.Kind == StringIntrinsicKind::CopyUTF16 ||
              Op.Kind == StringIntrinsicKind::Inflate;
  if (Void ? !CB.getType()->isVoidTy() : !CB.getType()->isIntegerTy(32))
    return std::nullopt;
  for (unsigned I = 0; I != Arity; ++I) {
    Type *T = CB.getArgOperand(I)->getType();
    bool Pointer = I == 0 || (Equals ? I == 1 : !Char && I == 2);
    if (Pointer) {
      if (!T->isPointerTy() || T->getPointerAddressSpace() != 1)
        return std::nullopt;
    } else if (!T->isIntegerTy(
                   (Char || Op.isConversion()) && I == Arity - 1 ? 1 : 32))
      return std::nullopt;
  }
  if (!Equals) {
    auto *C = dyn_cast<ConstantInt>(CB.getArgOperand(Arity - 1));
    if (!C)
      return std::nullopt;
    if (Char || Op.isConversion()) {
      Op.Layout = !C->isZero();
      if (Char)
        Op.Encoding = Op.Layout;
    } else {
      if (C->getZExtValue() > 3)
        return std::nullopt;
      Op.Encoding = C->getZExtValue();
    }
  }
  return Op;
}

inline std::optional<int64_t> stringConstantInt(Value *V) {
  if (auto *C = dyn_cast<ConstantInt>(V))
    return C->getSExtValue();
  return std::nullopt;
}

inline constexpr unsigned StringScalarLimit = 16;
inline constexpr unsigned StringSearchComparisonLimit = 64;

} // namespace llvm::jeandle
#endif
