//===- MemoryBarrier.cpp - Java memory ordering semantics -----------------===//
//
// Copyright (c) 2026, the Jeandle-LLVM Authors. All Rights Reserved.
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#include "llvm/IR/Jeandle/MemoryBarrier.h"
#include "llvm/IR/IntrinsicsAArch64.h"
#include "llvm/IR/Jeandle/Attributes.h"
#include "llvm/IR/Jeandle/JeandleUtils.h"
#include "llvm/IR/Module.h"
#include "llvm/TargetParser/Triple.h"

using namespace llvm;

namespace llvm::jeandle {

static constexpr StringLiteral Names[] = {"jeandle.membar_loadload",
                                          "jeandle.membar_loadstore",
                                          "jeandle.membar_acquire",
                                          "jeandle.membar_storestore",
                                          "jeandle.membar_release",
                                          "jeandle.membar_storeload",
                                          "jeandle.membar_full",
                                          "jeandle.membar_cpuorder",
                                          "jeandle.membar_allocation_init",
                                          "jeandle.membar_constructor_freeze",
                                          "jeandle.membar_clone_source"};

StringRef getMemoryBarrierName(MemoryBarrierKind Kind) {
  return Names[static_cast<unsigned>(Kind)];
}

std::optional<MemoryBarrierKind> getMemoryBarrierKind(StringRef Name) {
  for (unsigned I = 0; I != std::size(Names); ++I)
    if (Name == Names[I])
      return static_cast<MemoryBarrierKind>(I);
  return std::nullopt;
}

uint8_t getMemoryBarrierObligation(MemoryBarrierKind Kind) {
  switch (Kind) {
  case MemoryBarrierKind::AllocationInit:
    return AllocationInitObligation;
  case MemoryBarrierKind::ConstructorFreeze:
    return ConstructorFreezeObligation;
  case MemoryBarrierKind::CloneSource:
    return CloneSourceObligation;
  default:
    return NoBarrierObligation;
  }
}

bool isReplayPublicationBarrier(const CallBase *CB) {
  const Function *F = CB ? CB->getCalledFunction() : nullptr;
  if (!F || F->getName() != ReplayPublicationBarrierName ||
      !isa<CallInst>(CB) || CB->hasOperandBundles() ||
      !CB->getType()->isVoidTy() || !F->isVarArg() || F->arg_size() != 1 ||
      !F->getArg(0)->getType()->isIntegerTy(32) ||
      CB->getCallingConv() != CallingConv::Hotspot_JIT ||
      F->getCallingConv() != CallingConv::Hotspot_JIT || CB->arg_empty())
    return false;
  auto *Count = dyn_cast<ConstantInt>(CB->getArgOperand(0));
  if (!Count || !Count->getType()->isIntegerTy(32) || Count->isZero() ||
      Count->getZExtValue() != (CB->arg_size() - 1) / 2 ||
      CB->arg_size() % 2 != 1)
    return false;
  for (unsigned I = 1; I < CB->arg_size(); I += 2) {
    auto *Mask = dyn_cast<ConstantInt>(CB->getArgOperand(I + 1));
    if (!isWideOopType(CB->getArgOperand(I)->getType()) || !Mask ||
        !Mask->getType()->isIntegerTy(32) || Mask->isZero() ||
        (Mask->getZExtValue() &
         ~(AllocationInitObligation | ConstructorFreezeObligation)))
      return false;
  }
  return true;
}

SmallVector<ReplayPublicationOwner, 4>
getReplayPublicationOwners(const CallBase &CB) {
  assert(isReplayPublicationBarrier(&CB));
  SmallVector<ReplayPublicationOwner, 4> Owners;
  for (unsigned I = 1; I < CB.arg_size(); I += 2)
    Owners.push_back(
        {CB.getArgOperand(I),
         static_cast<uint8_t>(
             cast<ConstantInt>(CB.getArgOperand(I + 1))->getZExtValue())});
  return Owners;
}

CallInst *
createReplayPublicationBarrier(IRBuilder<> &B,
                               ArrayRef<ReplayPublicationOwner> Owners) {
  assert(!Owners.empty());
  Module &M = *B.GetInsertBlock()->getModule();
  FunctionType *Ty = FunctionType::get(B.getVoidTy(), {B.getInt32Ty()}, true);
  GlobalValue *Named = M.getNamedValue(ReplayPublicationBarrierName);
  Function *F = dyn_cast_or_null<Function>(Named);
  if (Named && (!F || F->getFunctionType() != Ty))
    report_fatal_error("invalid Jeandle replay publication declaration");
  if (!F)
    F = Function::Create(Ty, GlobalValue::ExternalLinkage,
                         ReplayPublicationBarrierName, M);
  F->setCallingConv(CallingConv::Hotspot_JIT);
  F->addFnAttr(llvm::Attribute::NoUnwind);
  F->addFnAttr(llvm::Attribute::WillReturn);
  F->addFnAttr("gc-leaf-function");
  SmallVector<Value *, 9> Args{B.getInt32(Owners.size())};
  for (const ReplayPublicationOwner &Owner : Owners) {
    assert(isWideOopType(Owner.Receiver->getType()) && Owner.Obligations &&
           !(Owner.Obligations &
             ~(AllocationInitObligation | ConstructorFreezeObligation)));
    Args.push_back(Owner.Receiver);
    Args.push_back(B.getInt32(Owner.Obligations));
  }
  CallInst *Call = B.CreateCall(F, Args);
  Call->setCallingConv(CallingConv::Hotspot_JIT);
  for (unsigned I = 1; I < Args.size(); I += 2)
    Call->addParamAttr(I, llvm::Attribute::getWithCaptureInfo(
                              B.getContext(), CaptureInfo::none()));
  return Call;
}

bool isMemoryBarrierCall(const CallBase *CB) {
  const Function *F = CB ? CB->getCalledFunction() : nullptr;
  auto Kind = F ? getMemoryBarrierKind(F->getName()) : std::nullopt;
  if (!Kind || !isa<CallInst>(CB) || CB->hasOperandBundles() ||
      !CB->getType()->isVoidTy() || F->isVarArg() ||
      CB->getCallingConv() != CallingConv::Hotspot_JIT)
    return false;
  unsigned Args = getMemoryBarrierObligation(*Kind) ? 1 : 0;
  return CB->arg_size() == Args && F->arg_size() == Args &&
         (!Args || isWideOopType(CB->getArgOperand(0)->getType()));
}

bool isObjectMemoryBarrier(const CallBase *CB) {
  return isMemoryBarrierCall(CB) &&
         getMemoryBarrierObligation(
             *getMemoryBarrierKind(CB->getCalledFunction()->getName()));
}

CallInst *createMemoryBarrier(IRBuilder<> &B, MemoryBarrierKind Kind,
                              Value *Receiver) {
  bool HasReceiver = getMemoryBarrierObligation(Kind);
  assert(HasReceiver == (Receiver != nullptr));
  assert(!Receiver || isWideOopType(Receiver->getType()));
  SmallVector<Type *, 1> Types;
  SmallVector<Value *, 1> Args;
  if (Receiver) {
    Types.push_back(Receiver->getType());
    Args.push_back(Receiver);
  }
  Module &M = *B.GetInsertBlock()->getModule();
  FunctionType *Ty = FunctionType::get(B.getVoidTy(), Types, false);
  GlobalValue *Named = M.getNamedValue(getMemoryBarrierName(Kind));
  Function *F = dyn_cast_or_null<Function>(Named);
  if (Named && (!F || F->getFunctionType() != Ty))
    report_fatal_error("invalid Jeandle memory barrier declaration");
  if (!F)
    F = Function::Create(Ty, GlobalValue::ExternalLinkage,
                         getMemoryBarrierName(Kind), M);
  F->setCallingConv(CallingConv::Hotspot_JIT);
  F->addFnAttr(llvm::Attribute::NoUnwind);
  F->addFnAttr(llvm::Attribute::WillReturn);
  F->addFnAttr("gc-leaf-function");
  if (HasReceiver)
    F->addParamAttr(0, llvm::Attribute::getWithCaptureInfo(
                           B.getContext(), CaptureInfo::none()));
  auto *Call = B.CreateCall(F, Args);
  Call->setCallingConv(CallingConv::Hotspot_JIT);
  return Call;
}

void emitMemoryBarrier(IRBuilder<> &B, MemoryBarrierKind Kind) {
  switch (Kind) {
  case MemoryBarrierKind::CPUOrder:
  case MemoryBarrierKind::CloneSource:
    B.CreateFence(AtomicOrdering::SequentiallyConsistent,
                  SyncScope::SingleThread);
    return;
  case MemoryBarrierKind::AllocationInit:
  case MemoryBarrierKind::ConstructorFreeze:
  case MemoryBarrierKind::StoreStore:
    if (B.GetInsertBlock()->getModule()->getTargetTriple().isAArch64()) {
      B.CreateIntrinsic(Intrinsic::aarch64_dmb, {}, {B.getInt32(10)});
      return;
    }
    [[fallthrough]];
  case MemoryBarrierKind::Release:
    B.CreateFence(AtomicOrdering::Release);
    return;
  case MemoryBarrierKind::LoadLoad:
  case MemoryBarrierKind::LoadStore:
  case MemoryBarrierKind::Acquire:
    B.CreateFence(AtomicOrdering::Acquire);
    return;
  case MemoryBarrierKind::StoreLoad:
  case MemoryBarrierKind::Full:
    B.CreateFence(AtomicOrdering::SequentiallyConsistent);
    return;
  }
  llvm_unreachable("invalid memory barrier kind");
}

SmallVector<MemoryBarrierKind, 2> getReplayMemoryBarriers(uint8_t Obligations,
                                                          bool HasStores) {
  SmallVector<MemoryBarrierKind, 2> Kinds;
  if (HasStores || (Obligations & AllocationInitObligation))
    Kinds.push_back(MemoryBarrierKind::AllocationInit);
  else if (Obligations & ConstructorFreezeObligation)
    Kinds.push_back(MemoryBarrierKind::ConstructorFreeze);
  if (Obligations & CloneSourceObligation)
    Kinds.push_back(MemoryBarrierKind::CloneSource);
  return Kinds;
}

bool copyNeedsInitializationBarrier(const CallBase &CB) {
  llvm::Attribute KindAttr = CB.getFnAttr(Attribute::CopyKind);
  StringRef Kind =
      KindAttr.isStringAttribute() ? KindAttr.getValueAsString() : StringRef();
  if (Kind == Attribute::CopyKindCloneInstance ||
      Kind == Attribute::CopyKindCloneArray ||
      Kind == Attribute::CopyKindCloneReferenceArray)
    return true;
  if (!CB.hasFnAttr(Attribute::CopyTightlyCoupledAllocation) ||
      CB.arg_size() < 3)
    return false;
  auto *Alloc = dyn_cast<CallBase>(CB.getArgOperand(2)->stripPointerCasts());
  return Alloc && Alloc->getCalledFunction() &&
         Alloc->getCalledFunction()->getName() == "jeandle.new_array";
}

} // namespace llvm::jeandle
