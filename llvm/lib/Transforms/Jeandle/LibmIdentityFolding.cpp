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
// Specializes selected Jeandle libm calls without changing the runtime's
// numerical contract. Unary identities use only exact zeros/ones. For pow,
// exponent zero returns one and exponent two uses the runtime's entry multiply.
// Exponent one retains NaN handling, and exponent one half uses sqrt only for
// positive bases. Constant signed-zero bases return positive zero. A reciprocal
// is exact for SharedRuntime_dpow, whose fdlibm entry shortcuts to division for
// non-NaN bases, but not for the x86 stub.
//
//===----------------------------------------------------------------------===//

#include "llvm/Transforms/Jeandle/LibmIdentityFolding.h"

#include "llvm/ADT/DenseMap.h"
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

enum class LibmKind { Pow, Sin, Cos, Tan, Log, Log10, Exp };
struct LibmCallee {
  LibmKind Kind;
  bool IsShared;
};

using CalleeMap = DenseMap<const Value *, LibmCallee>;

bool hasLibmType(FunctionType *FTy, LibmKind Kind) {
  unsigned Arity = Kind == LibmKind::Pow ? 2 : 1;
  return !FTy->isVarArg() && FTy->getReturnType()->isDoubleTy() &&
         FTy->getNumParams() == Arity &&
         llvm::all_of(FTy->params(), [](Type *Ty) { return Ty->isDoubleTy(); });
}

void collectLibmCallees(Module &M, CalleeMap &Callees) {
  static constexpr struct {
    StringLiteral Name;
    LibmKind Kind;
  } Entries[] = {{"dpow", LibmKind::Pow}, {"dsin", LibmKind::Sin},
                 {"dcos", LibmKind::Cos}, {"dtan", LibmKind::Tan},
                 {"dlog", LibmKind::Log}, {"dlog10", LibmKind::Log10},
                 {"dexp", LibmKind::Exp}};
  for (auto [Name, Kind] : Entries) {
    if (Function *Stub = M.getFunction(("StubRoutines_" + Name).str()))
      if (Stub->isDeclaration() && hasLibmType(Stub->getFunctionType(), Kind))
        Callees.try_emplace(Stub, LibmCallee{Kind, false});
    if (GlobalAlias *Shared =
            M.getNamedAlias(("SharedRuntime_" + Name).str())) {
      auto *Address = dyn_cast<ConstantExpr>(Shared->getAliasee());
      auto *FTy = dyn_cast<FunctionType>(Shared->getValueType());
      // RuntimeRoutine emits an opaque pointer alias; function-typed aliases
      // are also usable in standalone IR. Validate the call's type separately.
      if ((!Shared->getValueType()->isPointerTy() &&
           (!FTy || !hasLibmType(FTy, Kind))) ||
          !Address || Address->getOpcode() != Instruction::IntToPtr)
        continue;
      Callees.try_emplace(Shared, LibmCallee{Kind, true});
      // Frontend calls use the absolute address rather than the alias.
      Callees.try_emplace(Address, LibmCallee{Kind, true});
    }
  }
}

Constant *foldUnaryCall(const CallInst &Call, LibmKind Kind) {
  auto *Arg = dyn_cast<ConstantFP>(Call.getArgOperand(0));
  if (!Arg)
    return nullptr;
  switch (Kind) {
  case LibmKind::Sin:
  case LibmKind::Tan:
    return Arg->isZero() ? Arg : nullptr;
  case LibmKind::Cos:
  case LibmKind::Exp:
    return Arg->isZero() ? ConstantFP::get(Call.getType(), 1.0) : nullptr;
  case LibmKind::Log:
  case LibmKind::Log10:
    return Arg->isExactlyValue(1.0) ? ConstantFP::get(Call.getType(), 0.0)
                                    : nullptr;
  case LibmKind::Pow:
    llvm_unreachable("Expected unary libm entry");
  }
  llvm_unreachable("Unknown libm entry");
}

// Keep residual calls recognizable across CSE, inlining and loop cloning.
// Equal string call-site attributes survive attribute intersection; unknown
// instruction metadata can be discarded when the intervening O3 merges calls.
constexpr StringLiteral PowSlowPath = "jeandle.pow.slow";

enum class PowSpecialization { One, Half, Reciprocal };

void specializeGuardedCall(CallInst &Call, PowSpecialization Kind) {
  IRBuilder<> Builder(&Call);
  Value *Base = Call.getArgOperand(0);
  // A call argument may be undef or poison without causing immediate UB.
  // Stabilize the value before branching and use that same choice in both
  // paths, so the guard cannot introduce UB or disagree with its result.
  if (!isGuaranteedNotToBeUndefOrPoison(Base))
    Base = Builder.CreateFreeze(Base, "pow.base");
  Value *Safe =
      Kind != PowSpecialization::Half
          ? Builder.CreateFCmpORD(Base, Base, "pow.non_nan")
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
  if (Kind == PowSpecialization::Reciprocal)
    FastResult = IRBuilder<>(FastTerm).CreateFDiv(
        ConstantFP::get(Base->getType(), 1.0), Base, "pow.reciprocal");
  else if (Kind == PowSpecialization::Half)
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
  // The libm symbols carry Jeandle semantics; a same-named symbol in a
  // plain LLVM module must not be folded. Gate on the Jeandle module mark,
  // mirroring JavaOpLengthFolding.
  Module *M = F.getParent();
  if (!M || !M->getNamedMetadata(jeandle::Metadata::JavaMethodCompilation))
    return PreservedAnalyses::all();

  CalleeMap Callees;
  collectLibmCallees(*M, Callees);
  if (Callees.empty())
    return PreservedAnalyses::all();

  SmallVector<CallInst *, 4> Calls;
  for (Instruction &I : instructions(F))
    if (auto *Call = dyn_cast<CallInst>(&I))
      if (!Call->isMustTailCall() && !Call->hasOperandBundles())
        Calls.push_back(Call);

  bool Changed = false;
  bool ChangedCFG = false;
  for (CallInst *Call : Calls) {
    auto It = Callees.find(Call->getCalledOperand()->stripPointerCasts());
    if (It == Callees.end() ||
        !hasLibmType(Call->getFunctionType(), It->second.Kind))
      continue;
    LibmCallee Callee = It->second;
    Value *Replacement = nullptr;
    if (Callee.Kind != LibmKind::Pow) {
      Replacement = foldUnaryCall(*Call, Callee.Kind);
    } else {
      const auto *Exp = dyn_cast<ConstantFP>(Call->getArgOperand(1));
      if (!Exp)
        continue;
      Value *Base = Call->getArgOperand(0);
      if (Exp->isZero())
        Replacement = ConstantFP::get(Base->getType(), 1.0);
      else if (Exp->isExactlyValue(0.5) && isa<ConstantFP>(Base) &&
               cast<ConstantFP>(Base)->isZero())
        Replacement = ConstantFP::get(Base->getType(), 0.0);
      else if (Exp->isExactlyValue(2.0)) {
        IRBuilder<> Builder(Call);
        // Multiplication observes the base twice, while the runtime call
        // observes it once. Correlate a possibly undef argument first.
        if (!isGuaranteedNotToBeUndef(Base))
          Base = Builder.CreateFreeze(Base, "pow.base");
        Replacement = Builder.CreateFMul(Base, Base, "pow.identity");
      } else if (!Call->hasFnAttr(PowSlowPath)) {
        std::optional<PowSpecialization> Kind;
        if (Exp->isExactlyValue(1.0))
          Kind = PowSpecialization::One;
        else if (Exp->isExactlyValue(0.5))
          Kind = PowSpecialization::Half;
        else if (Callee.IsShared && Exp->isExactlyValue(-1.0))
          Kind = PowSpecialization::Reciprocal;
        if (Kind) {
          specializeGuardedCall(*Call, *Kind);
          Changed = ChangedCFG = true;
        }
      }
    }
    if (Replacement) {
      Call->replaceAllUsesWith(Replacement);
      Call->eraseFromParent();
      Changed = true;
    }
  }

  if (!Changed)
    return PreservedAnalyses::all();
  // Only the unguarded identities leave the CFG unchanged.
  return ChangedCFG ? PreservedAnalyses::none()
                    : PreservedAnalyses::allInSet<CFGAnalyses>();
}
