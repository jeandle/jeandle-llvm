//===- CHADevirtualization.cpp - Jeandle CHA devirtualization -------------===//
//
// Copyright (c) 2026, the Jeandle-LLVM Authors. All Rights Reserved.
//
// Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM
// Exceptions. See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//
//
// Converts guarded dynamic Java call sites to static calls when HotSpot class
// hierarchy analysis proves a unique concrete target and the compiled-code
// call-site metadata can be kept in sync.
//
//===----------------------------------------------------------------------===//

#include "llvm/Transforms/Jeandle/CHADevirtualization.h"
#include "llvm/ADT/DenseMap.h"
#include "llvm/ADT/SmallVector.h"
#include "llvm/ADT/StringSwitch.h"
#include "llvm/Analysis/BlockFrequencyInfo.h"
#include "llvm/Analysis/BranchProbabilityInfo.h"
#include "llvm/Analysis/DomTreeUpdater.h"
#include "llvm/Analysis/DominanceFrontier.h"
#include "llvm/Analysis/LoopInfo.h"
#include "llvm/Analysis/PostDominators.h"
#include "llvm/IR/Attributes.h"
#include "llvm/IR/BasicBlock.h"
#include "llvm/IR/CallingConv.h"
#include "llvm/IR/Constants.h"
#include "llvm/IR/Dominators.h"
#include "llvm/IR/IRBuilder.h"
#include "llvm/IR/InstIterator.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/Jeandle/Attributes.h"
#include "llvm/IR/Jeandle/Deoptimization.h"
#include "llvm/IR/Jeandle/GCStrategy.h"
#include "llvm/IR/Jeandle/InvokeType.h"
#include "llvm/IR/Jeandle/JavaType.h"
#include "llvm/IR/Jeandle/JeandleUtils.h"
#include "llvm/IR/Jeandle/Metadata.h"
#include "llvm/IR/Jeandle/VMCallback.h"
#include "llvm/IR/LLVMContext.h"
#include "llvm/IR/Metadata.h"
#include "llvm/IR/Module.h"
#include "llvm/Support/Casting.h"
#include "llvm/Support/Debug.h"
#include "llvm/Transforms/Jeandle/JeandleTransformUtils.h"
#include "llvm/Transforms/Utils/BasicBlockUtils.h"

#include <cstdint>
#include <optional>

#define DEBUG_TYPE "cha-devirtualization"

using namespace llvm;
using jeandle::JavaType;

namespace {

int getDeoptBCI(const InvokeInst &CB) {
  std::optional<OperandBundleUse> Deopt =
      CB.getOperandBundle(LLVMContext::OB_deopt);
  auto *BCI = dyn_cast<ConstantInt>(Deopt->Inputs[0].get());
  return static_cast<int>(BCI->getSExtValue());
}

int getPatchSize(const Module *M, const char *PatchType) {
  NamedMDNode *NMD = M->getNamedMetadata(PatchType);
  assert(NMD && NMD->getNumOperands() == 1 && "expected patch size metadata");
  MDNode *PatchNode = NMD->getOperand(0);
  assert(PatchNode && PatchNode->getNumOperands() == 1 && "must be");
  return mdconst::extract<ConstantInt>(PatchNode->getOperand(0))
      ->getSExtValue();
}

void updateStaticOptVirtualCallAttrs(InvokeInst &CB, int PatchSize) {
  CB.addParamAttr(0, Attribute::NoUndef);
  CB.addParamAttr(
      0, Attribute::get(CB.getContext(), jeandle::Attribute::RuntimeLive));
  CB.removeFnAttr(jeandle::Attribute::StatepointNumPatchBytes);
  CB.addFnAttr(Attribute::get(CB.getContext(),
                              jeandle::Attribute::StatepointNumPatchBytes,
                              std::to_string(PatchSize)));
  CB.addFnAttr(
      Attribute::get(CB.getContext(), jeandle::Attribute::MonomorphicTarget));
}

int getOperandOopHandleLoadId(InvokeInst &CB, int ArgNum) {
  Value *Receiver = CB.getArgOperand(ArgNum);
  if (auto *LI = dyn_cast<LoadInst>(Receiver)) {
    std::optional<int> OptionOopId = getOopHandleLoadId(LI);
    if (OptionOopId) {
      return *OptionOopId;
    }
  }
  return -1;
}

void changeCallAttr(InvokeInst &CB, const char *const AttrName,
                    const StringRef &AttrValue) {
  CB.removeFnAttr(AttrName);
  CB.addFnAttr(Attribute::get(CB.getContext(), AttrName, AttrValue));
}

Function *getFunction(uintptr_t Method, const StringRef &MethodName,
                      FunctionType *FuncType, LLVMContext &Context, Module *M) {
  FunctionCallee Callee = M->getOrInsertFunction(MethodName, FuncType);
  Function *Func = cast<Function>(Callee.getCallee());

  Func->setCallingConv(CallingConv::Hotspot_JIT);
  Func->setGC(jeandle::JeandleGC);
  Func->addFnAttr(llvm::Attribute::get(
      Context, llvm::jeandle::Attribute::JavaMethod, std::to_string(Method)));
  return Func;
}

Value *tryNarrowJavaObjType(Value *Receiver, JavaType HolderType,
                            DominatorTree &DT, InvokeInst &CB) {
  JavaType ReceiverType = jeandle::getJavaType(Receiver, &DT, &CB);
  ReceiverType = jeandle::typeIntersect(HolderType, ReceiverType);
  if (ReceiverType.Klass == 0) {
    LLVM_DEBUG(dbgs() << "Receiver argument type mismatch.\n");
    return nullptr;
  }
  if (HolderType != ReceiverType) {
    return insertJavaTypeAssume(Receiver, ReceiverType, &CB);
  }
  return Receiver;
}

StringRef getByteCodeName(const StringRef &IntrinsicName) {
  return StringSwitch<StringRef>(IntrinsicName)
      .Case("_linkToVirtual", "invokevirtual")
      .Case("_linkToStatic", "invokestatic")
      .Case("_linkToSpecial", "invokespecial")
      .Case("_linkToInterface", "invokeinterface")
      .DefaultUnreachable("unexpected method handle intrinsic");
}

void copyAttributeAndMetadata(InvokeInst &OldCB, InvokeInst &NewCB,
                              unsigned ArgSize) {
  AttributeList OldAttrs = OldCB.getAttributes();
  SmallVector<AttributeSet, 8> NewArgAttrs;
  for (unsigned I = 0; I < ArgSize; ++I)
    NewArgAttrs.push_back(OldAttrs.getParamAttrs(I));

  AttributeList NewAttrs =
      AttributeList::get(OldCB.getContext(), OldAttrs.getFnAttrs(),
                         OldAttrs.getRetAttrs(), NewArgAttrs);

  NewCB.setAttributes(NewAttrs);
  NewCB.setCallingConv(OldCB.getCallingConv());
  NewCB.removeFnAttr(jeandle::Attribute::MhIntrinsicName);
  if (OldCB.hasMetadata(jeandle::Metadata::InlineScopeID)) {
    NewCB.setMetadata(jeandle::Metadata::InlineScopeID,
                      OldCB.getMetadata(jeandle::Metadata::InlineScopeID));
  }
}

InvokeInst *createNewCB(InvokeInst &CB, bool IsMonomorphicTarget, int PatchSize,
                        FunctionType *FuncType, uintptr_t Method,
                        const StringRef &MethodName,
                        const StringRef &ByteCodeName, uintptr_t Holder,
                        uint64_t Id) {
  SmallVector<OperandBundleDef, 4> Bundles;
  CB.getOperandBundlesAsDefs(Bundles);
  SmallVector<Value *, 8> NewArgs;
  for (unsigned I = 0, E = CB.arg_size() - 1; I != E; ++I) {
    NewArgs.push_back(CB.getArgOperand(I));
  }

  Module *M = CB.getModule();
  auto *NewCB = InvokeInst::Create(
      getFunction(Method, MethodName, FuncType, CB.getContext(), M),
      CB.getNormalDest(), CB.getUnwindDest(), NewArgs, Bundles, CB.getName(),
      CB.getIterator());
  copyAttributeAndMetadata(CB, *NewCB, NewArgs.size());
  changeCallAttr(*NewCB, jeandle::Attribute::StatepointNumPatchBytes,
                 std::to_string(PatchSize));
  changeCallAttr(*NewCB, jeandle::Attribute::Bytecode, ByteCodeName);
  changeCallAttr(*NewCB, jeandle::Attribute::DeclaredHolder,
                 std::to_string(Holder));
  NewCB->removeFnAttr(jeandle::Attribute::MonomorphicTarget);
  if (IsMonomorphicTarget) {
    NewCB->addFnAttr(
        Attribute::get(CB.getContext(), jeandle::Attribute::MonomorphicTarget));
  }
  return NewCB;
}

bool hasReceiver(const StringRef &IntrinsicName) {
  return StringSwitch<bool>(IntrinsicName)
      .Cases({"invokespecial", "invokevirtual", "invokeinterface"}, true)
      .Case("invokestatic", false)
      .DefaultUnreachable("Should not reach here.");
}

InvokeInst *optimizeMhIntrinsic(InvokeInst &CB, Function &F, DominatorTree &DT,
                                DomTreeUpdater &DTU,
                                const jeandle::VMCallbacks &Callbacks,
                                uintptr_t Caller,
                                const StringRef &IntrinsicName) {
  assert(IntrinsicName != "_invokeBasic" &&
         "_invokeBaisc is treated in normal path.");
  const bool CanBeOptimizedIntrinsic =
      StringSwitch<bool>(IntrinsicName)
          .Cases({"_linkToVirtual", "_linkToStatic", "_linkToSpecial",
                  "_linkToInterface"},
                 true)
          .Default(false);
  if (!CanBeOptimizedIntrinsic) {
    return nullptr;
  }

  const bool IsVirtualOrInterface = (IntrinsicName == "_linkToVirtual" ||
                                     IntrinsicName == "_linkToInterface");

  uintptr_t Callee = 0;
  uintptr_t Holder = 0;
  uint64_t Id = 0;
  getFunctionJavaMethod(*CB.getCalledFunction(), Callee);
  getUIntPtrFnAttr(CB, jeandle::Attribute::DeclaredHolder, Holder);
  getUIntFnAttr(CB, jeandle::Attribute::StatepointID, Id);
  assert(Id >= 0 && Id <= 0xffffffff && "must be 32 bits.");
  assert(Callee != 0 && Holder != 0 && "should be a java call");

  int OopId = getOperandOopHandleLoadId(CB, CB.arg_size() - 1);
  if (OopId == -1) {
    LLVM_DEBUG(dbgs() << "optimize_method_handle_intrinsic: not constant"
                      << "\n");
    return nullptr;
  }
  jeandle::CHAOptInfo CHAOptInfo =
      jeandle::CHAOptInfo::decode(Callbacks.GetCHAOptInfo(
          Caller, Callee, Holder, /*Unused*/ 0, /*Unused*/ 0,
          /*Unused*/ jeandle::ILLEGAL, OopId));
  if (CHAOptInfo.Method == 0)
    return nullptr;

  const int IsStatic = CHAOptInfo.isStatic();
  DenseMap<int, Value *> JavaTypeAssumeCB;
  llvm::SmallVector<llvm::Type *> ArgTypes;
  bool NarrowSuccess = true;
  if (!IsStatic) {
    Value *Receiver = CB.getArgOperand(0);
    if (jeandle::isJavaOopType(Receiver->getType())) {
      JavaType HolderType = {
          Callbacks.GetSignatureAccessingKlass(CHAOptInfo.Method), false};
      JavaTypeAssumeCB[0] = tryNarrowJavaObjType(Receiver, HolderType, DT, CB);
      NarrowSuccess &= JavaTypeAssumeCB[0] != nullptr;
    }
    ArgTypes.push_back(java2llvm(jeandle::T_OBJECT, CB.getContext()));
  }
  for (int I = 0; NarrowSuccess && I < CHAOptInfo.argsNum(); ++I) {
    Value *Op = CB.getArgOperand(I + !IsStatic);
    if (jeandle::isJavaOopType(Op->getType())) {
      JavaType ArgsDeclareType = {
          Callbacks.GetSignatureArgTypeKlass(CHAOptInfo.Method, I), false};
      JavaTypeAssumeCB[I + !IsStatic] =
          tryNarrowJavaObjType(Op, ArgsDeclareType, DT, CB);
      NarrowSuccess &= JavaTypeAssumeCB[I + !IsStatic] != nullptr;
    }
    ArgTypes.push_back(
        java2llvm(static_cast<jeandle::HotspotBasicType>(
                      Callbacks.GetSignatureArgType(CHAOptInfo.Method, I)),
                  CB.getContext()));
  }
  if (!NarrowSuccess) {
    for (auto &[_, Value] : JavaTypeAssumeCB) {
      if (CallInst *Inst = dyn_cast_or_null<CallInst>(Value)) {
        Inst->eraseFromParent();
      }
    }
    return nullptr;
  }

  Type *RetType =
      java2llvm(static_cast<jeandle::HotspotBasicType>(
                    Callbacks.GetSignatureArgType(CHAOptInfo.Method, -1)),
                CB.getContext());
  for (auto &[ArgIdx, AssumeCB] : JavaTypeAssumeCB) {
    CB.setArgOperand(ArgIdx, AssumeCB);
  }
  FunctionType *FuncType = FunctionType::get(RetType, ArgTypes, false);

  jeandle::CHADestKind DestKind = jeandle::CHADestKind::Illegal;
  int PatchSize = 0;
  if (IsVirtualOrInterface) {
    if (CHAOptInfo.canBeStaticallyBound()) {
      DestKind = jeandle::OptVirtualCall;
      PatchSize =
          getPatchSize(CB.getModule(), jeandle::Metadata::StaticCallPatchSize);
    } else {
      DestKind = jeandle::VirtualCall;
      CHAOptInfo.MethodName =
          std::string("__jeandle_dynamic_call.") + CHAOptInfo.MethodName;
      PatchSize =
          getPatchSize(CB.getModule(), jeandle::Metadata::DynamicCallPatchSize);
    }
  } else {
    DestKind = jeandle::StaticCall;
    PatchSize =
        getPatchSize(CB.getModule(), jeandle::Metadata::StaticCallPatchSize);
  }
  Callbacks.UpdateCallSite(static_cast<int64_t>(Id), DestKind,
                           CHAOptInfo.Method);
  StringRef NewBCName = getByteCodeName(IntrinsicName);

  if (hasReceiver(NewBCName)) {
    std::optional<OperandBundleDef> PreCallDeopt = createPreCallDeoptBundle(CB);
    if (!PreCallDeopt)
      return nullptr;
    int BCI = getDeoptBCI(CB);
    std::string Prefix = "null_check_bci_" + std::to_string(BCI);

    BasicBlock *NullCheckFail =
        insertNullCheck(CB, CB.getOperand(0), Prefix, &DTU);
    if (!NullCheckFail)
      return nullptr;
    IRBuilder<> BuilderFail(NullCheckFail);
    buildDeoptimize(BuilderFail, *CB.getModule(),
                    jeandle::Deoptimization::Reason_null_check,
                    jeandle::Deoptimization::Action_maybe_recompile,
                    *PreCallDeopt);
  }

  return createNewCB(CB, DestKind != jeandle::VirtualCall, PatchSize, FuncType,
                     CHAOptInfo.Method, CHAOptInfo.MethodName, NewBCName,
                     CHAOptInfo.holder(), Id);
}

bool optimizeCallSite(InvokeInst &CB, Function &F, DominatorTree &DT,
                      DomTreeUpdater &DTU,
                      const jeandle::VMCallbacks &Callbacks, uintptr_t Caller) {
  using jeandle::JavaType;
  bool IsInvokeBasic = false;
  if (CB.hasFnAttr(jeandle::Attribute::MhIntrinsicName)) {
    StringRef IntrinsicName =
        CB.getFnAttr(jeandle::Attribute::MhIntrinsicName).getValueAsString();
    if (IntrinsicName != "_invokeBasic") {
      InvokeInst *NewCB =
          optimizeMhIntrinsic(CB, F, DT, DTU, Callbacks, Caller, IntrinsicName);
      if (NewCB) {
        CB.replaceAllUsesWith(NewCB);
        CB.eraseFromParent();
        return optimizeCallSite(*NewCB, F, DT, DTU, Callbacks, Caller);
      }
      return false;
    }
    IsInvokeBasic = true;
  }

  Module *M = CB.getModule();

  // quick check if this is a java virtual call.
  if (CB.hasFnAttr(jeandle::Attribute::MonomorphicTarget) && !IsInvokeBasic)
    return false;

  Attribute BC = CB.getFnAttr(jeandle::Attribute::Bytecode);
  if (!checkStringAttr(BC))
    return false;
  StringRef Bytecode = BC.getValueAsString();
  jeandle::InvokeType InvokeKind = jeandle::getInvokeType(Bytecode);
  Value *Receiver = CB.getArgOperand(0);
  assert(Receiver->getType()->isPointerTy() &&
         "virtual call receiver must be a pointer");

  uintptr_t Callee = 0;
  uintptr_t Holder = 0;
  uint64_t Id = 0;
  getFunctionJavaMethod(*CB.getCalledFunction(), Callee);
  getUIntPtrFnAttr(CB, jeandle::Attribute::DeclaredHolder, Holder);
  getUIntFnAttr(CB, jeandle::Attribute::StatepointID, Id);
  assert(Id >= 0 && Id <= 0xffffffff && "must be 32 bits.");
  // CHADevirtualization normal path only handles invokevirtual,
  // invokeinterface, or methodhandle intrinsic with _invokeBasic intrinsic ID.
  assert(Callee != 0 && Holder != 0 &&
         (InvokeKind == jeandle::InvokeVirtual ||
          InvokeKind == jeandle::InvokeInterface || IsInvokeBasic) &&
         "should be a java call");

  jeandle::JavaType ReceiverType = jeandle::getJavaType(Receiver, &DT, &CB);
  int OopId = -1;
  if (IsInvokeBasic) {
    OopId = getOperandOopHandleLoadId(CB, 0);
    if (OopId == -1) {
      LLVM_DEBUG(dbgs() << "optimize_method_handle_intrinsic: _invokeBasic: "
                        << "receiver is not constant\n");
      return false;
    }
  }

  auto CHAOptInfo = jeandle::CHAOptInfo::decode(
      Callbacks.GetCHAOptInfo(Caller, Callee, Holder, ReceiverType.Klass,
                              ReceiverType.Exact, InvokeKind, OopId));
  if (CHAOptInfo.constraint() == 0)
    return false;

  int BCI = getDeoptBCI(CB);
  std::string Prefix = "cha_bci_" + std::to_string(BCI);

  if (!IsInvokeBasic) {
    std::optional<OperandBundleDef> PreCallDeopt = createPreCallDeoptBundle(CB);
    if (!PreCallDeopt)
      return false;

    BasicBlock *CheckInstanceofFail = insertCheckInstanceOf(
        CB, Receiver, CHAOptInfo.constraint(), Prefix, &DTU);
    assert(CheckInstanceofFail && "failed to insert check_instanceof");

    IRBuilder<> BuilderFail(CheckInstanceofFail);
    buildDeoptimize(BuilderFail, *CB.getModule(), CHAOptInfo.deoptReason(),
                    jeandle::Deoptimization::Action_none, *PreCallDeopt);
  }

  updateStaticOptVirtualCallAttrs(
      CB, getPatchSize(M, jeandle::Metadata::StaticCallPatchSize));
  CB.setCalledFunction(getOrInsertJavaMethodFunction(
      *CB.getModule(), CHAOptInfo.MethodName, CB.getFunctionType(),
      CHAOptInfo.Method, CHAOptInfo.isAccessor()));

  if (!Callbacks.UpdateCallSite(static_cast<int64_t>(Id),
                                jeandle::OptVirtualCall, 0)) {
    return false;
  }
  LLVM_DEBUG(dbgs() << "CHA: devirtualized " << CB << "\n");
  DTU.flush();
  return true;
}

} // namespace

PreservedAnalyses CHADevirtualization::run(Function &F,
                                           FunctionAnalysisManager &FAM) {
  Module *M = F.getParent();
  if (!M->getNamedMetadata(jeandle::Metadata::JavaMethodCompilation))
    return PreservedAnalyses::all();
  if (F.hasAvailableExternallyLinkage())
    return PreservedAnalyses::all();

  const jeandle::VMCallbacks *Callbacks = jeandle::getVMCallbacks();
  assert(Callbacks && Callbacks->IsSubtype && Callbacks->GetCommonSuperKlass &&
         Callbacks->GetFieldType && Callbacks->IsInterface &&
         Callbacks->IsObjectKlass && Callbacks->IsEffectivelyFinal &&
         Callbacks->GetCHAOptInfo && Callbacks->UpdateCallSite &&
         Callbacks->GetSignatureAccessingKlass &&
         Callbacks->GetSignatureArgType &&
         Callbacks->GetSignatureArgTypeKlass && "VMCallbacks must be set");

  DominatorTree &DT = FAM.getResult<DominatorTreeAnalysis>(F);
  DomTreeUpdater DTU(DT, DomTreeUpdater::UpdateStrategy::Lazy);

  SmallVector<InvokeInst *, 16> Calls;
  for (Instruction &I : instructions(F)) {
    if (auto *CB = dyn_cast<InvokeInst>(&I))
      Calls.push_back(CB);
  }

  bool Changed = false;
  uintptr_t Caller = 0;
  getFunctionJavaMethod(F, Caller);
  for (InvokeInst *CB : Calls)
    Changed |= optimizeCallSite(*CB, F, DT, DTU, *Callbacks, Caller);

  if (!Changed)
    return PreservedAnalyses::all();

  PreservedAnalyses PA;
  PA.preserve<DominatorTreeAnalysis>();
  return PA;
}
