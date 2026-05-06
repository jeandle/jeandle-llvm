//===- PEATransformManager.cpp - PEA Transform Manager -------------------===//
//
// Copyright (c) 2026, the Jeandle-LLVM Authors. All Rights Reserved.
//
// Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM
// Exceptions. See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#include "llvm/Transforms/Jeandle/PEA/PEATransformManager.h"
#include "llvm/IR/Function.h"
#include "llvm/IR/Instructions.h"
#include "llvm/Support/Debug.h"

#define DEBUG_TYPE "pea-transform-manager"

using namespace llvm;
using namespace jeandle;

static void applyTransform(PEATransformRecord &TR, Function &F);

void PEATransformManager::addTransform(const PEATransformRecord &TR) {
  Transforms.push_back(TR);
}

void PEATransformManager::applyAll(Function &F) {
  if (empty()) return;

  std::stable_sort(Transforms.begin(), Transforms.end(),
    [](const PEATransformRecord &A, const PEATransformRecord &B) {
      return A.Order < B.Order;
    });

  LLVM_DEBUG(dbgs() << "PEATransformManager: Applying " << size() << " transforms\n");

  for (PEATransformRecord &TR : Transforms) {
    applyTransform(TR, F);
  }
}

static void applyTransform(PEATransformRecord &TR, Function &F) {
  LLVM_DEBUG(dbgs() << "PEATransformManager: Transform kind=" << TR.Kind
                    << " at " << *TR.TargetInst << "\n");

  switch (TR.Kind) {
  case PEATransformRecord::MaterializeAlloc:
    LLVM_DEBUG(dbgs() << "  TODO: MaterializeAlloc\n");
    break;

  case PEATransformRecord::ReplaceLoad:
    LLVM_DEBUG(dbgs() << "  TODO: ReplaceLoad\n");
    break;

  case PEATransformRecord::ReplaceCallArg:
    LLVM_DEBUG(dbgs() << "  TODO: ReplaceCallArg\n");
    break;

  case PEATransformRecord::RemoveMonitorenter:
    LLVM_DEBUG(dbgs() << "  TODO: RemoveMonitorenter\n");
    break;

  case PEATransformRecord::RemoveMonitorexit:
    LLVM_DEBUG(dbgs() << "  TODO: RemoveMonitorexit\n");
    break;

  case PEATransformRecord::RemoveAllocCall:
    LLVM_DEBUG(dbgs() << "  TODO: RemoveAllocCall\n");
    break;

  case PEATransformRecord::CleanupDeadCode:
    LLVM_DEBUG(dbgs() << "  TODO: CleanupDeadCode\n");
    break;
  }
}
