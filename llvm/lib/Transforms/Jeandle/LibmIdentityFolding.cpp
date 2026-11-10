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
// Specializes constant-exponent dpow calls for the two callee
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
// Guarded specializations:
//   y == 1.0: non-NaN bases return unchanged. NaNs keep the original call,
//              preserving runtime quieting and payload selection.
//   y == 0.5: positive bases use sqrt. Non-positive and NaN bases keep the
//              original call, preserving negative-zero and NaN behavior.
//
// Deliberately NOT folded:
//   y == -1.0: the fdlibm port shortcuts to a single one/x division
//              (sharedRuntimeTrans.cpp), but the x86 stub has no y==-1
//              entry shortcut, so 1/x is not bit-exact against both runtime
//              entries.
//
//===----------------------------------------------------------------------===//

#include "llvm/Transforms/Jeandle/LibmIdentityFolding.h"

#include "llvm/ADT/SmallPtrSet.h"
#include "llvm/ADT/SmallVector.h"
#include "llvm/Analysis/ValueTracking.h"
#include "llvm/IR/Constants.h"
#include "llvm/IR/GlobalAlias.h"
#include "llvm/IR/IRBuilder.h"
#include "llvm/IR/InstIterator.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/Jeandle/Metadata.h"
#include "llvm/IR/Module.h"
#include "llvm/Support/Debug.h"
#include "llvm/Transforms/Utils/BasicBlockUtils.h"

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

// Keep residual calls recognizable across CSE, inlining and loop cloning.
// Equal string call-site attributes survive attribute intersection; unknown
// instruction metadata can be discarded when the intervening O3 merges calls.
constexpr StringLiteral PowSlowPath = "jeandle.pow.slow";

void specializeGuardedCall(CallInst &Call, bool IsOne) {
  IRBuilder<> Builder(&Call);
  Value *Base = Call.getArgOperand(0);
  // A call argument may be undef or poison without causing immediate UB.
  // Stabilize the value before branching and use that same choice in both
  // paths, so the guard cannot introduce UB or disagree with its result.
  if (!isGuaranteedNotToBeUndefOrPoison(Base))
    Base = Builder.CreateFreeze(Base, "pow.base");
  Value *Safe =
      IsOne ? Builder.CreateFCmpORD(Base, Base, "pow.non_nan")
            : Builder.CreateFCmpOGT(Base, ConstantFP::get(Base->getType(), 0.0),
                                    "pow.positive");
  Instruction *FastTerm, *SlowTerm;
  SplitBlockAndInsertIfThenElse(Safe, &Call, &FastTerm, &SlowTerm);
  FastTerm->getParent()->setName("pow.fast");
  SlowTerm->getParent()->setName("pow.slow");
  Call.getParent()->setName("pow.merge");

  auto *SlowCall = cast<CallInst>(Call.clone());
  SlowCall->setTailCallKind(CallInst::TCK_None);
  SlowCall->setArgOperand(0, Base);
  SlowCall->addFnAttr(Attribute::get(Call.getContext(), PowSlowPath));
  SlowCall->insertBefore(SlowTerm->getIterator());

  Value *FastResult = Base;
  if (!IsOne)
    FastResult = IRBuilder<>(FastTerm).CreateUnaryIntrinsic(
        Intrinsic::sqrt, Base, nullptr, "pow.sqrt");

  PHINode *Result =
      PHINode::Create(Call.getType(), 2, "pow.result", Call.getIterator());
  Result->addIncoming(FastResult, FastTerm->getParent());
  Result->addIncoming(SlowCall, SlowTerm->getParent());
  Call.replaceAllUsesWith(Result);
  Call.eraseFromParent();
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
    if (!Exp)
      continue;
    if (Exp->isExactlyValue(2.0) || Exp->isZero())
      Folds.push_back(CB);
    else if (!CB->hasFnAttr(PowSlowPath) && !CB->hasOperandBundles() &&
             (Exp->isExactlyValue(1.0) || Exp->isExactlyValue(0.5)))
      Folds.push_back(CB);
  }

  if (Folds.empty())
    return PreservedAnalyses::all();

  bool ChangedCFG = false;
  for (CallBase *CB : Folds) {
    const auto *Exp = cast<ConstantFP>(CB->getArgOperand(1));
    if (Exp->isExactlyValue(1.0) || Exp->isExactlyValue(0.5)) {
      specializeGuardedCall(*cast<CallInst>(CB), Exp->isExactlyValue(1.0));
      ChangedCFG = true;
      continue;
    }
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

  // Only the unguarded identities leave the CFG unchanged.
  return ChangedCFG ? PreservedAnalyses::none()
                    : PreservedAnalyses::allInSet<CFGAnalyses>();
}
