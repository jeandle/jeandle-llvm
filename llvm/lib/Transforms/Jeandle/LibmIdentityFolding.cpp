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
// Exponent one retains NaN handling, and exponent one half uses sqrt(|x|) for
// non-negative bases (both signed zeros included). Constant signed-zero bases
// return positive zero. A reciprocal
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
#include "llvm/IR/Jeandle/VMCallback.h"
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

// Selector matching the LibmEntry values in VMCallback.h: kind index times
// two plus the SharedRuntime bit.
int libmEntrySelector(LibmCallee Callee) {
  int KindIndex;
  switch (Callee.Kind) {
  case LibmKind::Sin:
    KindIndex = 0;
    break;
  case LibmKind::Cos:
    KindIndex = 1;
    break;
  case LibmKind::Tan:
    KindIndex = 2;
    break;
  case LibmKind::Log:
    KindIndex = 3;
    break;
  case LibmKind::Log10:
    KindIndex = 4;
    break;
  case LibmKind::Exp:
    KindIndex = 5;
    break;
  case LibmKind::Pow:
    KindIndex = 6;
    break;
  }
  return KindIndex * 2 + (Callee.IsShared ? 1 : 0);
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
  // The half fast path admits both signed zeros: pow(+-0, 0.5) is +0.0 and
  // sqrt(|-0.0|) is +0.0, so evaluating sqrt on the absolute value keeps the
  // zeros on the fast path while NaN and negative bases stay on the runtime
  // call (oge is unordered-false, so NaN takes the slow path).
  Value *Safe =
      Kind != PowSpecialization::Half
          ? Builder.CreateFCmpORD(Base, Base, "pow.non_nan")
          : Builder.CreateFCmpOGE(Base, ConstantFP::get(Base->getType(), 0.0),
                                  "pow.nonneg");
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
        Intrinsic::sqrt,
        IRBuilder<>(FastTerm).CreateUnaryIntrinsic(Intrinsic::fabs, Base),
        nullptr, "pow.sqrt");

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

  // Constant arguments can additionally be evaluated on the selected runtime
  // entry itself through the VM callback, making the folded value bit
  // identical to interpreted execution by construction. Without a callback
  // (standalone opt without a callback log) only the exact identities below
  // apply.
  const jeandle::VMCallbacks *CB = jeandle::getVMCallbacks();

  bool Changed = false;
  bool ChangedCFG = false;
  for (CallInst *Call : Calls) {
    auto It = Callees.find(Call->getCalledOperand()->stripPointerCasts());
    if (It == Callees.end() ||
        !hasLibmType(Call->getFunctionType(), It->second.Kind))
      continue;
    LibmCallee Callee = It->second;
    Value *Replacement = nullptr;
    // Fully constant arguments fold to the value the VM reports for the very
    // runtime entry this call targets, which is bit-identical to interpreted
    // execution by construction and strictly better than any guarded
    // specialization. Without the callback (standalone opt without a
    // callback log) the exact identities below still apply.
    if (CB && CB->EvaluateLibm) {
      auto *Base = dyn_cast<ConstantFP>(Call->getArgOperand(0));
      bool IsPow = Callee.Kind == LibmKind::Pow;
      if (Base && (!IsPow || isa<ConstantFP>(Call->getArgOperand(1)))) {
        int64_t ExponentBits = 0;
        if (IsPow)
          ExponentBits = cast<ConstantFP>(Call->getArgOperand(1))
                             ->getValueAPF()
                             .bitcastToAPInt()
                             .getSExtValue();
        int64_t ResultBits = CB->EvaluateLibm(
            libmEntrySelector(Callee),
            Base->getValueAPF().bitcastToAPInt().getSExtValue(), ExponentBits);
        Call->replaceAllUsesWith(ConstantFP::get(
            Call->getContext(),
            APFloat(Base->getValueAPF().getSemantics(),
                    APInt(64, static_cast<uint64_t>(ResultBits)))));
        Call->eraseFromParent();
        Changed = true;
        continue;
      }
    }
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
          // specializeGuardedCall erased the call; nothing remains to fold.
          continue;
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
