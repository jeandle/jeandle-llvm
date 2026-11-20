//===- CharacterIntrinsics.h - Character operation ABI -----------*- C++
//-*-===//
//
// Copyright (c) 2026, the Jeandle-LLVM Authors. All Rights Reserved.
// Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM
// Exceptions. See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#ifndef LLVM_IR_JEANDLE_CHARACTERINTRINSICS_H
#define LLVM_IR_JEANDLE_CHARACTERINTRINSICS_H

#include "llvm/IR/Constants.h"
#include "llvm/IR/Instructions.h"
#include <optional>

namespace llvm::jeandle {

struct CharacterIntrinsic {
  bool Scan = false;
  bool SourceBytes = false;
  bool ASCII = false;
  unsigned countIndex() const { return Scan ? 2 : 4; }
};

inline std::optional<CharacterIntrinsic>
decodeCharacterIntrinsic(const CallBase &CB) {
  const Function *F = CB.getCalledFunction();
  if (!F || CB.getFunctionType() != F->getFunctionType() ||
      CB.getFunctionType()->isVarArg() || isa<CallBrInst>(CB) ||
      CB.getCallingConv() != CallingConv::Hotspot_JIT ||
      F->getCallingConv() != CallingConv::Hotspot_JIT ||
      !CB.getType()->isIntegerTy(32))
    return std::nullopt;
  CharacterIntrinsic Op;
  if (F->getName() == "jeandle.count_positives")
    Op.Scan = true;
  else if (F->getName() != "jeandle.encode_array")
    return std::nullopt;
  unsigned Arity = Op.Scan ? 3 : 7;
  if (CB.arg_size() != Arity)
    return std::nullopt;
  for (unsigned I = 0; I != Arity; ++I) {
    Type *T = CB.getArgOperand(I)->getType();
    if (I == 0 || (!Op.Scan && I == 2)) {
      if (!T->isPointerTy() || T->getPointerAddressSpace() != 1)
        return std::nullopt;
    } else if (!T->isIntegerTy(I >= 5 ? 1 : 32))
      return std::nullopt;
  }
  if (!Op.Scan) {
    const auto *Bytes = dyn_cast<ConstantInt>(CB.getArgOperand(5));
    const auto *ASCII = dyn_cast<ConstantInt>(CB.getArgOperand(6));
    if (!Bytes || !ASCII)
      return std::nullopt;
    Op.SourceBytes = !Bytes->isZero();
    Op.ASCII = !ASCII->isZero();
  }
  return Op;
}

inline constexpr unsigned CharacterScalarLimit = 16;

} // namespace llvm::jeandle

#endif
