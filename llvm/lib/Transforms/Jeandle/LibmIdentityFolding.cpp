//===- LibmIdentityFolding.cpp - Fold exact Math.pow runtime identities ---===//
//
// Copyright (c) 2026, The Jeandle-LLVM Authors. All Rights Reserved.
//
// Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM
// Exceptions. See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//
//
// Folds dpow(x, 2.0) -> x*x and dpow(x, +-0.0) -> 1.0 for the two callee
// forms the Jeandle frontend emits for Math.pow:
//   - the external declaration @StubRoutines_dpow (platform stub path), or
//   - the absolute-address constant aliased as @SharedRuntime_dpow, whose
//     call operand is the aliasee constant itself.
//
// Exactness of the folded identities, input by input:
//   y == 2.0:  x*x is the correctly rounded square. The fdlibm port
//              returns x*x for y==2 before any range reduction, and the
//              x86 stub multiplies at entry, so every input -- signed
//              zeros (x*x gives +0.0 for both), infinities, and NaN
//              payloads -- agrees bit for bit; a multiply quiets a
//              signaling NaN exactly the way both entries do.
//   y == +-0.0: the fdlibm port tests (iy|ly)==0 before its NaN check and
//              returns 1.0, and IEEE 754 requires pow(x, +-0) == 1 for
//              every x including NaN, so a constant 1.0 matches on every
//              input.
//
// Deliberately NOT folded:
//   y == 1.0 -> x: both runtime entries quiet a signaling-NaN base
//              (fdlibm's NaN check runs before its y==1 shortcut, and the
//              stub's general path quiets as well), while returning x
//              untouched would preserve the signaling payload bits.
//   y == -1.0: fdlibm has no y==-1 shortcut; its general path may differ
//              from 1/x by an ulp.
//   y == 0.5:  no constant identity; the guarded sqrt specialization is
//              built by the frontend, which can create the control flow.
//
//===----------------------------------------------------------------------===//

#include "llvm/Transforms/Jeandle/LibmIdentityFolding.h"

#include "llvm/ADT/SmallPtrSet.h"
#include "llvm/ADT/SmallVector.h"
#include "llvm/IR/Constants.h"
#include "llvm/IR/GlobalAlias.h"
#include "llvm/IR/IRBuilder.h"
#include "llvm/IR/InstIterator.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/Jeandle/Metadata.h"
#include "llvm/IR/Module.h"
#include "llvm/Support/Debug.h"

#define DEBUG_TYPE "jeandle-libm-identity-folding"

using namespace llvm;

namespace {

// The callee values a dpow call can reference: the stub declaration, the
// SharedRuntime alias, and the alias's aliasee constant (calls emitted by
// the frontend use the aliasee directly). Constants are uniqued, so
// identical inttoptr expressions compare by pointer.
void collectDpowCallees(Module &M, SmallPtrSetImpl<const Value *> &Callees) {
  if (Function *Stub = M.getFunction("StubRoutines_dpow"))
    Callees.insert(Stub);
  if (GlobalAlias *Shared = M.getNamedAlias("SharedRuntime_dpow")) {
    Callees.insert(Shared);
    Callees.insert(Shared->getAliasee());
  }
}

bool isDpowCall(const CallBase &CB,
                const SmallPtrSetImpl<const Value *> &Callees) {
  // The frontend emits plain calls; an invoke carries exception edges whose
  // removal would change the CFG, and a musttail call must stay a call.
  if (!isa<CallInst>(CB) || CB.isMustTailCall())
    return false;
  if (!Callees.contains(CB.getCalledOperand()->stripPointerCasts()))
    return false;
  // Only the exact (double, double) -> double dpow shape, in case a symbol
  // of the same name is reused with a different signature.
  FunctionType *FTy = CB.getFunctionType();
  return FTy->getReturnType()->isDoubleTy() && FTy->getNumParams() == 2 &&
         FTy->getParamType(0)->isDoubleTy() &&
         FTy->getParamType(1)->isDoubleTy();
}

} // namespace

PreservedAnalyses LibmIdentityFolding::run(Function &F,
                                           FunctionAnalysisManager &FAM) {
  // The dpow symbols carry Jeandle semantics; a same-named symbol in a
  // plain LLVM module must not be folded. Gate on the Jeandle module mark,
  // mirroring JavaOpLengthFolding.
  Module *M = F.getParent();
  if (!M || !M->getNamedMetadata(jeandle::Metadata::JavaMethodCompilation))
    return PreservedAnalyses::all();

  SmallPtrSet<const Value *, 4> Callees;
  collectDpowCallees(*M, Callees);
  if (Callees.empty())
    return PreservedAnalyses::all();

  // Collect first, rewrite after the walk: folding erases the call, which
  // would invalidate the instruction iterator.
  SmallVector<CallBase *, 4> Folds;
  for (Instruction &I : instructions(F)) {
    auto *CB = dyn_cast<CallBase>(&I);
    if (!CB || !isDpowCall(*CB, Callees))
      continue;
    auto *Exp = dyn_cast<ConstantFP>(CB->getArgOperand(1));
    if (Exp && (Exp->isExactlyValue(2.0) || Exp->isZero()))
      Folds.push_back(CB);
  }

  if (Folds.empty())
    return PreservedAnalyses::all();

  for (CallBase *CB : Folds) {
    const auto *Exp = cast<ConstantFP>(CB->getArgOperand(1));
    Value *Base = CB->getArgOperand(0);
    Value *Replacement =
        Exp->isZero()
            ? static_cast<Value *>(ConstantFP::get(Base->getType(), 1.0))
            : IRBuilder<>(CB).CreateFMul(Base, Base, "pow.identity");
    LLVM_DEBUG(dbgs() << "folded dpow identity in " << F.getName()
                      << ": exponent " << Exp->getValueAPF() << " -> "
                      << *Replacement << "\n");
    CB->replaceAllUsesWith(Replacement);
    CB->eraseFromParent();
  }

  // Calls were replaced by values without control-flow or memory effects;
  // the CFG is untouched.
  return PreservedAnalyses::allInSet<CFGAnalyses>();
}
