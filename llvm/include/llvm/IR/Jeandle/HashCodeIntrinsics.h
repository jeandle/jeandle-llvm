//===- HashCodeIntrinsics.h - Jeandle hash operation ABI -------*- C++ -*-===//
//
// Copyright (c) 2026, the Jeandle-LLVM Authors. All Rights Reserved.
// Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM
// Exceptions. See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//
//
// ABI description of the jeandle.vectorized_hashcode JavaOp for passes that
// need to recognize it before JavaOperationLower expands its body.
//
//===----------------------------------------------------------------------===//

#ifndef LLVM_IR_JEANDLE_HASHCODEINTRINSICS_H
#define LLVM_IR_JEANDLE_HASHCODEINTRINSICS_H

#include "llvm/IR/Constants.h"
#include "llvm/IR/Instructions.h"
#include <optional>

namespace llvm::jeandle {

// The exact frontend ABI:
//   i32 @jeandle.vectorized_hashcode(ptr addrspace(1) %array, i32 %fromIndex,
//                                    i32 %length, i32 %initialValue,
//                                    i32 %basicType)
// The frontend only emits the call when %basicType is a compile-time constant
// in the set the Java switch implements, so the decoder returns that constant
// as the BasicType value (whose numbering the Java T_* constants share).
inline std::optional<uint8_t> decodeVectorizedHashCode(const CallBase &CB) {
  const Function *F = CB.getCalledFunction();
  if (!F || CB.getFunctionType() != F->getFunctionType() ||
      CB.getFunctionType()->isVarArg() || isa<CallBrInst>(CB))
    return std::nullopt;
  if (F->getName() != "jeandle.vectorized_hashcode")
    return std::nullopt;
  if (CB.arg_size() != 5 || !CB.getType()->isIntegerTy(32))
    return std::nullopt;
  Type *Array = CB.getArgOperand(0)->getType();
  if (!Array->isPointerTy() || Array->getPointerAddressSpace() != 1)
    return std::nullopt;
  for (unsigned I = 1; I != 5; ++I)
    if (!CB.getArgOperand(I)->getType()->isIntegerTy(32))
      return std::nullopt;
  auto *C = dyn_cast<ConstantInt>(CB.getArgOperand(4));
  if (!C)
    return std::nullopt;
  switch (C->getZExtValue()) {
  case 4:  // T_BOOLEAN: unsigned bytes over a byte[] payload
  case 5:  // T_CHAR: unsigned native-order shorts (char[] or utf16 byte[])
  case 8:  // T_BYTE: signed bytes
  case 9:  // T_SHORT: signed shorts
  case 10: // T_INT
    return static_cast<uint8_t>(C->getZExtValue());
  default:
    return std::nullopt;
  }
}

// Bound both cell inspection and generated scalar work. Constant segments
// collapse to one multiply/add pair independently of their element count.
inline constexpr unsigned HashCodeMaxFoldLength = 128;
inline constexpr unsigned HashCodeScalarCostLimit = 64;

} // namespace llvm::jeandle

#endif // LLVM_IR_JEANDLE_HASHCODEINTRINSICS_H
