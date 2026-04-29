//===- PEATransformRecord.h - PEA Transform Record -----------------------===//
//
// Copyright (c) 2026, the Jeandle-LLVM Authors. All Rights Reserved.
//
// Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM
// Exceptions. See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#ifndef LLVM_TRANSFORMS_JEANDLE_PEA_TRANSFORM_RECORD_H
#define LLVM_TRANSFORMS_JEANDLE_PEA_TRANSFORM_RECORD_H

#include "llvm/IR/Instruction.h"
#include "llvm/IR/Value.h"

namespace llvm::jeandle {

struct PEATransformRecord {
  enum TransformKind {
    MaterializeAlloc,        // Create actual allocation at escape point
    ReplaceLoad,             // Replace Load with scalar value
    ReplaceCallArg,          // Replace Call argument
    RemoveMonitorenter,      // Remove lock operation
    RemoveMonitorexit,
    RemoveAllocCall,         // Remove virtual allocation
    CleanupDeadCode,         // Cleanup dead code

    // TODO(PEA-Deopt): Add lazy_object bundle generation for deoptimization
    // - CreateLazyObjectBundle: generate "lazy_object" operand bundle at deopt sites
    // - ReplaceDeoptArg: replace original object reference with lazy_object id
    // Format: [ "lazy_object"(alloc_id, klass, field_count, field_values...) ]
    // - alloc_id: unique identifier for virtual allocation
    // - klass: uintptr_t representing Java class (from AllocationNode)
    // - field_count: number of fields to materialize
    // - field_values: pointers to scalar variables holding field values
    // CreateLazyObjectBundle,
    // ReplaceDeoptArg,
  };

  TransformKind Kind;
  Instruction *TargetInst = nullptr;
  unsigned Order = 0;

  uint32_t AllocId = 0;
  uint32_t FieldOffset = 0;
  Value *FieldValue = nullptr;

  // TODO(PEA-Deopt): Add fields for lazy_object bundle
  // uintptr_t Klass = 0;
  // SmallVector<Value*> FieldValues;

  PEATransformRecord() = default;

  PEATransformRecord(TransformKind K, Instruction *I, unsigned O, uint32_t A)
      : Kind(K), TargetInst(I), Order(O), AllocId(A),
        FieldOffset(0), FieldValue(nullptr) {}
};

} // namespace llvm::jeandle

#endif // LLVM_TRANSFORMS_JEANDLE_PEA_TRANSFORM_RECORD_H