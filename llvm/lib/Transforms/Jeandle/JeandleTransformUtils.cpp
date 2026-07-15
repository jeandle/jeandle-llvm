//===- JeandleTransformUtils.cpp - Some common helper functions -----------===//
//
// Copyright (c) 2025, the Jeandle-LLVM Authors. All Rights Reserved.
//
// Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM
// Exceptions. See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#include "llvm/Transforms/Jeandle/JeandleTransformUtils.h"
#include "llvm/Analysis/DomTreeUpdater.h"
#include "llvm/IR/Jeandle/Deoptimization.h"
#include "llvm/IR/Jeandle/Metadata.h"
#include "llvm/IR/Module.h"
#include "llvm/Transforms/Utils/BasicBlockUtils.h"

namespace llvm {

namespace {

struct DeoptScopeInfo {
  unsigned BCIPairStart = 0;
  int BCI = -1;
};

[[noreturn]] void reportInvalidDeoptBundle(const CallBase &CB,
                                           const char *Reason) {
  std::string Message;
  raw_string_ostream OS(Message);
  OS << "JeandleTransformUtils: " << Reason;
  if (const Function *Caller = CB.getCaller())
    OS << " in " << Caller->getName();
  OS << ": " << CB;
  OS.flush();
  report_fatal_error(StringRef(Message));
}

DeoptScopeInfo findCurrentDeoptScope(const CallBase &CB) {
  auto Deopt = CB.getOperandBundle(LLVMContext::OB_deopt);
  if (!Deopt)
    reportInvalidDeoptBundle(CB, "missing deopt bundle for bci");

  for (unsigned I = Deopt->Inputs.size(); I > 1; --I) {
    auto *BCI0 = dyn_cast<ConstantInt>(Deopt->Inputs[I - 2].get());
    auto *BCI1 = dyn_cast<ConstantInt>(Deopt->Inputs[I - 1].get());
    if (!BCI0 || !BCI1 || !BCI0->getType()->isIntegerTy(32) ||
        !BCI1->getType()->isIntegerTy(32))
      continue;

    if (BCI0->getSExtValue() != BCI1->getSExtValue())
      reportInvalidDeoptBundle(CB, "mismatched adjacent i32 bci values");

    return {I - 2, static_cast<int>(BCI0->getSExtValue())};
  }

  reportInvalidDeoptBundle(CB, "missing adjacent i32 deopt bci pair");
}

} // namespace

static Function *getDeoptimizeCallee(Module &M, Type *RetTy) {
  Function *DeoptDecl = Intrinsic::getOrInsertDeclaration(
      &M, Intrinsic::experimental_deoptimize, {RetTy});
  DeoptDecl->setCallingConv(CallingConv::Hotspot_JIT);
  return DeoptDecl;
}

static CallInst *createConstraintInst(Value *Receiver, uintptr_t Constraint,
                                      IRBuilder<> &Builder, Function *CheckFn) {
  LLVMContext &Context = CheckFn->getContext();
  PointerType *KlassTy =
      PointerType::get(Context, jeandle::AddrSpace::CHeapAddrSpace);
  Value *ConstraintValue =
      Builder.CreateIntToPtr(Builder.getInt64(Constraint), KlassTy);

  FunctionCallee Callee(CheckFn);
  CallInst *Checkcast = Builder.CreateCall(Callee, {ConstraintValue, Receiver},
                                           ArrayRef<OperandBundleDef>{});
  Checkcast->setCallingConv(CallingConv::Hotspot_JIT);
  return Checkcast;
}

void buildDeoptimize(IRBuilder<> &Builder, Module &M,
                     jeandle::Deoptimization::DeoptReason Reason,
                     jeandle::Deoptimization::DeoptAction Action,
                     const OperandBundleDef &DeoptBundle) {
  Value *Request = Builder.getInt32(
      jeandle::Deoptimization::makeTrapRequest(Reason, Action));

  Function *Parent = Builder.GetInsertBlock()->getParent();
  Type *RetTy = Parent->getReturnType();
  Function *Callee = getDeoptimizeCallee(M, RetTy);
  CallInst *Call = Builder.CreateCall(Callee, {Request}, {DeoptBundle});
  Call->setCallingConv(CallingConv::Hotspot_JIT);

  if (RetTy->isVoidTy())
    Builder.CreateRetVoid();
  else
    Builder.CreateRet(Call);
}

BasicBlock *insertCheckInstanceOf(Instruction &Inst, Value *Receiver,
                                  uintptr_t Constraint, const StringRef &Prefix,
                                  DomTreeUpdater *DTU) {
  assert(Receiver->getType()->isPointerTy() && "Receiver must be a pointer");
  BasicBlock *BB = Inst.getParent();
  Module *M = Inst.getModule();
  Function *CheckFn = M->getFunction("jeandle.check_instanceof");
  assert(CheckFn && "jeandle.check_instanceof not found");

  LLVMContext &Context = Inst.getContext();

  BasicBlock *CheckcastPass = SplitBlock(BB, &Inst, DTU, nullptr, nullptr,
                                         Prefix + "_check_receiver_pass");
  BasicBlock *CheckcastFail = BasicBlock::Create(
      Context, Prefix + "_check_receiver_fail", BB->getParent(), CheckcastPass);

  BB->getTerminator()->eraseFromParent();
  IRBuilder<> BuilderOrigin(BB);
  CallInst *Checkcast =
      createConstraintInst(Receiver, Constraint, BuilderOrigin, CheckFn);

  BuilderOrigin.CreateCondBr(Checkcast, CheckcastPass, CheckcastFail);
  if (DTU) {
    DTU->applyUpdates({{DominatorTree::Insert, BB, CheckcastFail}});
    DTU->flush();
  }
  return CheckcastFail;
}

static std::pair<unsigned, unsigned> computeDeoptStackLayout(CallBase &CB) {
  OperandBundleUse Deopt = *CB.getOperandBundle(LLVMContext::OB_deopt);
  unsigned Slots = 0;
  unsigned InsertPos = findCurrentDeoptScope(CB).BCIPairStart + 2;
  // Each deopt scope starts with a duplicated BCI pair. Inlined scopes are
  // appended after their callers, so the current Java call site is the final
  // scope. Canonical per-scope order is:
  // [method], bci, bci, locals, stack, monitors, orig_pc.
  for (; InsertPos < Deopt.Inputs.size();) {
    auto *Encoding = dyn_cast<ConstantInt>(Deopt.Inputs[InsertPos].get());
    assert(Encoding != nullptr && "expected deopt value encoding");

    jeandle::DeoptValueEncoding DeoptInfo =
        jeandle::DeoptValueEncoding::decode(Encoding->getZExtValue());

    if (DeoptInfo.valueType() == jeandle::DeoptValueEncoding::StackType) {
      assert(Slots == DeoptInfo.index() && "Stack index should be in order.");
      Slots += jeandle::isDoubleWordType(DeoptInfo.basicType()) ? 2 : 1;
      InsertPos += 2;
    } else if (DeoptInfo.valueType() ==
               jeandle::DeoptValueEncoding::LocalType) {
      InsertPos += 2;
    } else {
      break;
    }
  }

  return {InsertPos, Slots};
}

OperandBundleDef createPreCallDeoptBundle(InvokeInst &CB) {
  assert(CB.hasOperandBundles() && "must have deopt bundle for java invoke");
  OperandBundleUse Deopt = *CB.getOperandBundle(LLVMContext::OB_deopt);

  SmallVector<Value *, 16> Args;
  Args.reserve(Deopt.Inputs.size() + CB.arg_size() * 2);

  LLVMContext &Context = CB.getContext();
  auto [InsertPos, StackIndex] = computeDeoptStackLayout(CB);

  for (unsigned I = 0; I < InsertPos; ++I)
    Args.push_back(Deopt.Inputs[I].get());

  for (Value *Arg : CB.args()) {
    jeandle::HotspotBasicType TypeKind =
        jeandle::LLVM2JavaComputational(Arg->getType());
    assert(TypeKind != jeandle::T_ILLEGAL);

    uint64_t Encoding =
        jeandle::DeoptValueEncoding(
            StackIndex, jeandle::DeoptValueEncoding::StackType, TypeKind)
            .encode();

    Args.push_back(ConstantInt::get(Type::getInt64Ty(Context), Encoding));
    Args.push_back(Arg);
    StackIndex += jeandle::isDoubleWordType(TypeKind) ? 2 : 1;
  }

  for (unsigned I = InsertPos; I < Deopt.Inputs.size(); ++I)
    Args.push_back(Deopt.Inputs[I].get());

  return OperandBundleDef("deopt", Args);
}

} // namespace llvm
