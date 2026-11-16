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
#include "llvm/ADT/SmallVector.h"
#include "llvm/ADT/StringSwitch.h"
#include "llvm/Analysis/BlockFrequencyInfo.h"
#include "llvm/Analysis/BranchProbabilityInfo.h"
#include "llvm/Analysis/DomTreeUpdater.h"
#include "llvm/Analysis/DominanceFrontier.h"
#include "llvm/Analysis/Jeandle/JavaTypeAnalysis.h"
#include "llvm/Analysis/LazyValueInfo.h"
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
#include <utility>

#define DEBUG_TYPE "cha-devirtualization"

using namespace llvm;
using jeandle::JavaType;

namespace {

// Read the VM-provided size of the stub patch for a given call kind.
int getPatchSize(const Module *M, const char *PatchType) {
  NamedMDNode *NMD = M->getNamedMetadata(PatchType);
  assert(NMD && NMD->getNumOperands() == 1 && "expected patch size metadata");
  MDNode *PatchNode = NMD->getOperand(0);
  assert(PatchNode && PatchNode->getNumOperands() == 1 && "must be");
  return mdconst::extract<ConstantInt>(PatchNode->getOperand(0))
      ->getSExtValue();
}

// Return the oop-handle identifier loaded by argument ArgNum, or -1 when
// the argument is not a load from a known oop handle.
// This is normally used to get the oop-handle for a constant java value.
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

// Intersect an oop's inferred type with the target signature. This only
// queries the type: returns false when the intersection is incompatible and
// reports the type to assume when the intersection is more precise than the
// current one. The assumption is materialized by the commit step so that the
// read epoch leaves the IR untouched.
bool queryNarrowedJavaObjType(Value *Operand, JavaType HolderType,
                              jeandle::JavaTypeAnalysisResult &JavaTypes,
                              InvokeInst &CB,
                              std::optional<JavaType> &AssumeType) {
  JavaType OperandType = JavaTypes.getJavaType(Operand, &CB);
  JavaType CastedOperandType = jeandle::typeIntersect(HolderType, OperandType);
  if (CastedOperandType.Klass == 0) {
    LLVM_DEBUG(dbgs() << "Receiver argument type mismatch.\n");
    return false;
  }
  if (CastedOperandType != OperandType)
    AssumeType = CastedOperandType;
  return true;
}

// The read-only analysis of one invoke. Phase one fills these in without
// touching the IR; phase two commits every plan in one batch.
struct CallSitePlan {
  enum PlanKind {
    // The site needs no rewrite or cannot be optimized.
    Skip,
    // Regular invokevirtual/invokeinterface devirtualization.
    Devirtualize,
    // Rebuild a linkTo* method-handle intrinsic invoke.
    MethodHandle,
    // Rebuild an _invokeBasic invoke.
    InvokeBasic,
  };

  PlanKind Kind = Skip;
  InvokeInst *CB = nullptr;
  uint64_t StatepointID = 0;
  jeandle::CHAOptInfo OptInfo;
  // Description of the rebuilt invoke, shared by the rebuilding paths.
  StringRef Bytecode;
  jeandle::CHADestKind DestKind = jeandle::CHADestKind::Illegal;
  int PatchSize = 0;
  FunctionType *TargetType = nullptr;
  bool RemoveTrailingMemberNameArg = true;
  bool MonomorphicTarget = true;
  // Method-handle narrowing: operand index -> type to assume.
  SmallVector<std::pair<unsigned, JavaType>, 8> NarrowedOperands;
  // Method-handle implicit null check, precomputed during the read epoch.
  std::optional<OperandBundleDef> NullCheckDeopt;
  std::string Prefix;
  // Regular devirtualization receiver guard, precomputed during read.
  std::optional<OperandBundleDef> ReceiverGuardDeopt;
};

// Translate a linkTo* intrinsic into the bytecode kind used by regular Java
// call-site metadata.
StringRef getByteCodeName(const StringRef &IntrinsicName) {
  return StringSwitch<StringRef>(IntrinsicName)
      .Case("_linkToVirtual", "invokevirtual")
      .Case("_linkToStatic", "invokestatic")
      .Case("_linkToSpecial", "invokespecial")
      .Case("_linkToInterface", "invokeinterface")
      .DefaultUnreachable("unexpected method handle intrinsic");
}

// Copy the attributes that remain valid after removing the trailing
// MemberName argument, together with the call's inline-scope metadata.
void copyAttributeAndMetadata(InvokeInst &OldCB, InvokeInst &NewCB,
                              unsigned ArgSize) {
  AttributeList OldAttrs = OldCB.getAttributes();
  SmallVector<AttributeSet, 8> NewArgAttrs;
  for (unsigned I = 0; I < ArgSize; ++I)
    NewArgAttrs.push_back(OldAttrs.getParamAttrs(I));

  AttributeSet RetAttrs = OldCB.getType() == NewCB.getType()
                              ? OldAttrs.getRetAttrs()
                              : AttributeSet{};
  AttributeList NewAttrs = AttributeList::get(
      OldCB.getContext(), OldAttrs.getFnAttrs(), RetAttrs, NewArgAttrs);

  NewCB.setAttributes(NewAttrs);
  NewCB.setCallingConv(OldCB.getCallingConv());
  NewCB.removeFnAttr(jeandle::Attribute::MhIntrinsicName);
  if (OldCB.hasMetadata(jeandle::Metadata::InlineScopeID)) {
    NewCB.setMetadata(jeandle::Metadata::InlineScopeID,
                      OldCB.getMetadata(jeandle::Metadata::InlineScopeID));
  }
}

// Rebuild a linkTo* invoke without its trailing MemberName operand. Preserve
// its control-flow edges and operand bundles while attaching the resolved
// target, bytecode kind, patch size, and receiver attributes.
InvokeInst *createNewCB(InvokeInst &CB, bool IsMonomorphicTarget, int PatchSize,
                        FunctionType *FuncType, uintptr_t Method,
                        const StringRef &MethodName,
                        const StringRef &ByteCodeName, uintptr_t Holder,
                        uint64_t Id, jeandle::CHADestKind DestKind,
                        bool IsAccessor,
                        bool RemoveTrailingMemberNameArg = true) {
  SmallVector<OperandBundleDef, 4> Bundles;
  CB.getOperandBundlesAsDefs(Bundles);
  SmallVector<Value *, 8> NewArgs;
  unsigned ArgSize =
      CB.arg_size() - static_cast<unsigned>(RemoveTrailingMemberNameArg);
  for (unsigned I = 0; I != ArgSize; ++I) {
    NewArgs.push_back(CB.getArgOperand(I));
  }

  Module *M = CB.getModule();
  Function *Target = getOrInsertJavaMethodFunction(*M, MethodName, FuncType,
                                                   Method, IsAccessor);
  assert(Target && "CHA target was prevalidated");
  auto *NewCB =
      InvokeInst::Create(Target, CB.getNormalDest(), CB.getUnwindDest(),
                         NewArgs, Bundles, CB.getName(), CB.getIterator());
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

  if (DestKind != jeandle::StaticCall) {
    NewCB->removeParamAttr(0, Attribute::NoUndef);
  }
  return NewCB;
}

bool hasReceiver(const StringRef &IntrinsicName) {
  return StringSwitch<bool>(IntrinsicName)
      .Cases({"invokespecial", "invokevirtual", "invokeinterface"}, true)
      .Case("invokestatic", false)
      .DefaultUnreachable("Should not reach here.");
}

// Resolve a linkTo* intrinsic through its constant MemberName and plan the
// rebuilt invoke. _invokeBasic follows the regular CHA path below because it
// does not require call reconstruction. The IR is only queried here.
std::optional<CallSitePlan>
planMhIntrinsic(InvokeInst &CB, jeandle::JavaTypeAnalysisResult &JavaTypes,
                const jeandle::VMCallbacks &Callbacks, uintptr_t Caller,
                const StringRef &IntrinsicName) {
  assert(IntrinsicName != "_invokeBasic" &&
         "_invokeBasic is treated in normal path.");
  const bool CanBeOptimizedIntrinsic =
      StringSwitch<bool>(IntrinsicName)
          .Cases({"_linkToVirtual", "_linkToStatic", "_linkToSpecial",
                  "_linkToInterface"},
                 true)
          .Default(false);
  if (!CanBeOptimizedIntrinsic)
    return std::nullopt;

  const bool IsVirtualOrInterface = (IntrinsicName == "_linkToVirtual" ||
                                     IntrinsicName == "_linkToInterface");

  // Collect the identities needed to resolve this particular call site.
  uintptr_t Callee = 0;
  uintptr_t Holder = 0;
  uint64_t Id = 0;
  getFunctionJavaMethod(*CB.getCalledFunction(), Callee);
  getUIntPtrFnAttr(CB, jeandle::Attribute::DeclaredHolder, Holder);
  getUIntFnAttr(CB, jeandle::Attribute::StatepointID, Id);
  assert(Id >= 0 && Id <= 0xffffffff && "must be 32 bits.");
  assert(Callee != 0 && Holder != 0 && "should be a java call");

  // The final argument for _linkTo* intrinsics is the MemberName oop handle.
  // Optimization is only safe when the handle can be identified as a constant.
  int OopId = getOperandOopHandleLoadId(CB, CB.arg_size() - 1);
  if (OopId == -1) {
    LLVM_DEBUG(dbgs() << "optimize_method_handle_intrinsic: not constant"
                      << "\n");
    return std::nullopt;
  }
  auto [ConstraintOrHolder, Method, TargetInfo, MethodName] =
      Callbacks.GetCHAOptInfo(Caller, Callee, Holder, /*Unused*/ 0,
                              /*Unused*/ 0, /*Unused*/ jeandle::ILLEGAL, OopId);
  jeandle::CHAOptInfo OptInfo{ConstraintOrHolder, Method, TargetInfo,
                              std::move(MethodName)};
  if (OptInfo.Method == 0)
    return std::nullopt;

  // Reconstruct the target signature and query how far reference operands
  // can be narrowed to the declared Java types returned by the callback.
  const int IsStatic = OptInfo.isStatic();
  SmallVector<std::pair<unsigned, JavaType>, 8> NarrowedOperands;
  llvm::SmallVector<llvm::Type *, 8> ArgTypes;
  bool NarrowSuccess = true;
  if (!IsStatic) {
    Value *Receiver = CB.getArgOperand(0);
    if (jeandle::isJavaOopType(Receiver->getType())) {
      JavaType HolderType = {
          Callbacks.GetSignatureAccessingKlass(OptInfo.Method), false};
      if (HolderType.Klass != 0) {
        std::optional<JavaType> AssumeType;
        NarrowSuccess &= queryNarrowedJavaObjType(Receiver, HolderType,
                                                  JavaTypes, CB, AssumeType);
        if (AssumeType)
          NarrowedOperands.emplace_back(0u, *AssumeType);
      }
    }
    ArgTypes.push_back(java2llvm(jeandle::T_OBJECT, CB.getContext()));
  }
  for (int I = 0; NarrowSuccess && I < OptInfo.argsNum(); ++I) {
    Value *Op = CB.getArgOperand(I + !IsStatic);
    if (jeandle::isJavaOopType(Op->getType())) {
      JavaType ArgsDeclareType = {
          Callbacks.GetSignatureArgTypeKlass(OptInfo.Method, I), false};
      if (ArgsDeclareType.Klass != 0) {
        std::optional<JavaType> AssumeType;
        NarrowSuccess &= queryNarrowedJavaObjType(Op, ArgsDeclareType,
                                                  JavaTypes, CB, AssumeType);
        if (AssumeType)
          NarrowedOperands.emplace_back(I + !IsStatic, *AssumeType);
      }
    }
    ArgTypes.push_back(
        java2llvm(static_cast<jeandle::HotspotBasicType>(
                      Callbacks.GetSignatureArgType(OptInfo.Method, I)),
                  CB.getContext()));
  }

  // Select the runtime call-site representation and its patching contract.
  // Virtual/interface targets that cannot be statically bound remain dynamic;
  // all other linkTo* variants use a patchable static sequence.
  jeandle::CHADestKind DestKind = jeandle::CHADestKind::Illegal;
  int PatchSize = 0;
  if (IsVirtualOrInterface) {
    if (OptInfo.canBeStaticallyBound()) {
      DestKind = jeandle::OptVirtualCall;
      PatchSize =
          getPatchSize(CB.getModule(), jeandle::Metadata::StaticCallPatchSize);
    } else {
      DestKind = jeandle::VirtualCall;
      OptInfo.MethodName =
          std::string("__jeandle_dynamic_call.") + OptInfo.MethodName;
      PatchSize =
          getPatchSize(CB.getModule(), jeandle::Metadata::DynamicCallPatchSize);
    }
  } else if (IntrinsicName == "_linkToSpecial") {
    DestKind = jeandle::OptVirtualCall;
    PatchSize =
        getPatchSize(CB.getModule(), jeandle::Metadata::StaticCallPatchSize);
  } else {
    DestKind = jeandle::StaticCall;
    PatchSize =
        getPatchSize(CB.getModule(), jeandle::Metadata::StaticCallPatchSize);
  }

  Type *RetType =
      java2llvm(static_cast<jeandle::HotspotBasicType>(
                    Callbacks.GetSignatureArgType(OptInfo.Method, -1)),
                CB.getContext());
  FunctionType *FuncType = FunctionType::get(RetType, ArgTypes, false);

  // Do not plan speculative type assumptions unless the target symbol is
  // compatible.
  if (!NarrowSuccess ||
      !canGetOrInsertJavaMethodFunction(*CB.getModule(), OptInfo.MethodName,
                                        FuncType, OptInfo.Method)) {
    return std::nullopt;
  }

  CallSitePlan Plan;
  Plan.Kind = CallSitePlan::MethodHandle;
  Plan.CB = &CB;
  Plan.StatepointID = Id;
  Plan.OptInfo = std::move(OptInfo);
  Plan.Bytecode = getByteCodeName(IntrinsicName);
  Plan.DestKind = DestKind;
  Plan.PatchSize = PatchSize;
  Plan.TargetType = FuncType;
  Plan.NarrowedOperands = std::move(NarrowedOperands);
  Plan.MonomorphicTarget = DestKind != jeandle::VirtualCall;

  // Precompute the implicit null check description. A malformed deopt bundle
  // must abort before the commit phase updates the VM call site.
  if (hasReceiver(Plan.Bytecode)) {
    int BCI = getCurrentDeoptBCI(CB);
    Plan.NullCheckDeopt = createPreCallDeoptBundle(CB);
    if (!Plan.NullCheckDeopt)
      return std::nullopt;
    Plan.Prefix = "null_check_bci_" + std::to_string(BCI);
  }
  return Plan;
}

// Commit a method-handle plan: materialize the narrowed operands, update the
// VM call-site record, then rebuild the invoke. The rebuilt call is queued for
// ordinary CHA refinement in the next read epoch.
bool commitMhIntrinsic(CallSitePlan &Plan, DomTreeUpdater &DTU,
                       jeandle::JavaTypeAnalysisResult &JavaTypes,
                       const jeandle::VMCallbacks &Callbacks,
                       SmallVectorImpl<InvokeInst *> &Deferred) {
  InvokeInst &CB = *Plan.CB;
  Module &M = *CB.getModule();

  SmallVector<std::pair<unsigned, Value *>, 8> AssumeValues;
  for (auto &[ArgIdx, AssumeType] : Plan.NarrowedOperands) {
    Value *Assume =
        insertJavaTypeAssume(CB.getArgOperand(ArgIdx), AssumeType, &CB);
    // Later arguments may be queried before this site's rewrite is committed.
    // The new call has no old users, so independent base results survive.
    JavaTypes.invalidate(*Assume);
    AssumeValues.emplace_back(ArgIdx, Assume);
  }

  if (!Callbacks.UpdateCallSite(static_cast<int64_t>(Plan.StatepointID),
                                Plan.DestKind, /*NeedAttached=*/true,
                                Plan.OptInfo.Method)) {
    for (auto &[_, Assume] : AssumeValues) {
      if (CallInst *Inst = dyn_cast_or_null<CallInst>(Assume)) {
        JavaTypes.invalidate(*Inst);
        Inst->eraseFromParent();
      }
    }
    return false;
  }

  // Notify while the old operands and uses are still intact.
  JavaTypes.invalidate({&CB}, /*CFGChanged=*/hasReceiver(Plan.Bytecode));
  // Commit the narrowed operands only after validation.
  for (auto &[ArgIdx, Assume] : AssumeValues)
    CB.setArgOperand(ArgIdx, Assume);

  // linkTo* performs the receiver null check implicitly. Preserve that
  // behavior before replacing it with a direct Java invoke.
  if (Plan.NullCheckDeopt) {
    BasicBlock *NullCheckFail =
        insertNullCheck(CB, CB.getOperand(0), Plan.Prefix, &DTU);
    IRBuilder<> BuilderFail(NullCheckFail);
    buildDeoptimize(BuilderFail, M, jeandle::Deoptimization::Reason_null_check,
                    jeandle::Deoptimization::Action_maybe_recompile,
                    *Plan.NullCheckDeopt);
  }

  InvokeInst *NewCB =
      createNewCB(CB, Plan.MonomorphicTarget, Plan.PatchSize, Plan.TargetType,
                  Plan.OptInfo.Method, Plan.OptInfo.MethodName, Plan.Bytecode,
                  Plan.OptInfo.holder(), Plan.StatepointID, Plan.DestKind,
                  Plan.OptInfo.isAccessor());
  JavaTypes.invalidate(CB);
  CB.replaceAllUsesWith(NewCB);
  CB.eraseFromParent();
  Deferred.push_back(NewCB);
  return true;
}

// Resolve an _invokeBasic target and plan its rebuilt signature. The IR is
// only queried here.
std::optional<CallSitePlan>
planInvokeBasic(InvokeInst &CB, const jeandle::VMCallbacks &Callbacks,
                uintptr_t Caller) {
  uintptr_t Callee = 0;
  uintptr_t Holder = 0;
  uint64_t Id = 0;
  getFunctionJavaMethod(*CB.getCalledFunction(), Callee);
  getUIntPtrFnAttr(CB, jeandle::Attribute::DeclaredHolder, Holder);
  getUIntFnAttr(CB, jeandle::Attribute::StatepointID, Id);
  if (Callee == 0 || Holder == 0 || Id > 0xffffffff)
    return std::nullopt;

  int OopId = getOperandOopHandleLoadId(CB, 0);
  if (OopId == -1)
    return std::nullopt;

  uintptr_t ScopeCaller = getCurrentDeoptMethod(CB, Caller);
  auto [ConstraintOrHolder, Method, TargetInfo, MethodName] =
      Callbacks.GetCHAOptInfo(ScopeCaller, Callee, Holder,
                              /*ReceiverKlass=*/0, /*IsExact=*/false,
                              jeandle::ILLEGAL, OopId);
  jeandle::CHAOptInfo OptInfo{ConstraintOrHolder, Method, TargetInfo,
                              std::move(MethodName)};
  if (OptInfo.Method == 0)
    return std::nullopt;

  bool IsStatic = OptInfo.isStatic();
  unsigned ExpectedArgSize =
      static_cast<unsigned>(OptInfo.argsNum()) + !IsStatic;
  if (ExpectedArgSize != CB.arg_size())
    return std::nullopt;

  SmallVector<Type *, 8> ArgTypes;
  if (!IsStatic)
    ArgTypes.push_back(java2llvm(jeandle::T_OBJECT, CB.getContext()));
  for (int I = 0; I < OptInfo.argsNum(); ++I) {
    Type *ArgType =
        java2llvm(static_cast<jeandle::HotspotBasicType>(
                      Callbacks.GetSignatureArgType(OptInfo.Method, I)),
                  CB.getContext());
    if (!ArgType)
      return std::nullopt;
    ArgTypes.push_back(ArgType);
  }
  for (unsigned I = 0; I < ArgTypes.size(); ++I) {
    if (ArgTypes[I] != CB.getArgOperand(I)->getType())
      return std::nullopt;
  }

  Type *RetType =
      java2llvm(static_cast<jeandle::HotspotBasicType>(
                    Callbacks.GetSignatureArgType(OptInfo.Method, -1)),
                CB.getContext());
  if (!RetType || (!CB.getType()->isVoidTy() && RetType != CB.getType()))
    return std::nullopt;

  CallSitePlan Plan;
  Plan.Kind = CallSitePlan::InvokeBasic;
  Plan.CB = &CB;
  Plan.StatepointID = Id;
  Plan.OptInfo = std::move(OptInfo);
  Plan.Bytecode = IsStatic ? "invokestatic" : "invokespecial";
  Plan.DestKind = IsStatic ? jeandle::StaticCall : jeandle::OptVirtualCall;
  Plan.PatchSize =
      getPatchSize(CB.getModule(), jeandle::Metadata::StaticCallPatchSize);
  Plan.TargetType = FunctionType::get(RetType, ArgTypes, false);
  Plan.RemoveTrailingMemberNameArg = false;
  return Plan;
}

// Commit an _invokeBasic plan by updating the VM call site and replacing the
// invoke with the resolved target.
bool commitInvokeBasic(CallSitePlan &Plan,
                       jeandle::JavaTypeAnalysisResult &JavaTypes,
                       const jeandle::VMCallbacks &Callbacks) {
  InvokeInst &CB = *Plan.CB;
  if (!Callbacks.UpdateCallSite(static_cast<int64_t>(Plan.StatepointID),
                                Plan.DestKind, /*NeedAttached=*/true,
                                Plan.OptInfo.Method))
    return false;

  InvokeInst *NewCB = createNewCB(
      CB, /*IsMonomorphicTarget=*/true, Plan.PatchSize, Plan.TargetType,
      Plan.OptInfo.Method, Plan.OptInfo.MethodName, Plan.Bytecode,
      Plan.OptInfo.holder(), Plan.StatepointID, Plan.DestKind,
      Plan.OptInfo.isAccessor(), Plan.RemoveTrailingMemberNameArg);
  // The helper creates a replacement without changing the old use graph.
  JavaTypes.invalidate(CB);
  if (!CB.getType()->isVoidTy())
    CB.replaceAllUsesWith(NewCB);
  CB.eraseFromParent();
  return true;
}

// Resolve a virtual or interface invoke through CHA and plan its receiver
// guard and target retargeting. The IR is only queried here.
std::optional<CallSitePlan>
planDevirtualize(InvokeInst &CB, jeandle::JavaTypeAnalysisResult &JavaTypes,
                 const jeandle::VMCallbacks &Callbacks, uintptr_t Caller) {
  Module *M = CB.getModule();

  // Calls already known to have a monomorphic target need no further work.
  if (CB.hasFnAttr(jeandle::Attribute::MonomorphicTarget))
    return std::nullopt;

  Attribute BC = CB.getFnAttr(jeandle::Attribute::Bytecode);
  if (!checkStringAttr(BC))
    return std::nullopt;
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
  // The normal CHA path only handles invokevirtual and invokeinterface.
  assert(Callee != 0 && Holder != 0 &&
         (InvokeKind == jeandle::InvokeVirtual ||
          InvokeKind == jeandle::InvokeInterface) &&
         "should be a java call");

  jeandle::JavaType ReceiverType = JavaTypes.getJavaType(Receiver, &CB);
  uintptr_t ScopeCaller = getCurrentDeoptMethod(CB, Caller);
  auto [ConstraintOrHolder, Method, DeoptReasonOrTargetInfo, MethodName] =
      Callbacks.GetCHAOptInfo(ScopeCaller, Callee, Holder, ReceiverType.Klass,
                              ReceiverType.Exact, InvokeKind, /*OopId=*/-1);
  jeandle::CHAOptInfo OptInfo{ConstraintOrHolder, Method,
                              DeoptReasonOrTargetInfo, std::move(MethodName)};
  if (OptInfo.constraint() == 0 ||
      !canGetOrInsertJavaMethodFunction(*M, OptInfo.MethodName,
                                        CB.getFunctionType(), OptInfo.Method)) {
    return std::nullopt;
  }

  // Everything that can abort or fail runs before the commit phase touches
  // either the VM or the IR: a malformed deopt bundle (diagnosed as fatal) or
  // a missing check declaration must not leave the VM record rewritten with no
  // matching IR change.
  int BCI = getCurrentDeoptBCI(CB);
  std::string Prefix = "cha_bci_" + std::to_string(BCI);
  OperandBundleDef PreCallDeopt = createPreCallDeoptBundle(CB);
  if (!M->getFunction("jeandle.check_instanceof")) {
    LLVM_DEBUG(dbgs() << "CHA: jeandle.check_instanceof declaration missing, "
                         "skipping site\n");
    return std::nullopt;
  }

  CallSitePlan Plan;
  Plan.Kind = CallSitePlan::Devirtualize;
  Plan.CB = &CB;
  Plan.StatepointID = Id;
  Plan.OptInfo = std::move(OptInfo);
  Plan.Prefix = std::move(Prefix);
  Plan.ReceiverGuardDeopt = std::move(PreCallDeopt);
  return Plan;
}

// Commit a devirtualization plan: update the VM call site, insert the receiver
// guard, then retarget the invoke.
bool commitDevirtualize(CallSitePlan &Plan, DomTreeUpdater &DTU,
                        jeandle::JavaTypeAnalysisResult &JavaTypes,
                        const jeandle::VMCallbacks &Callbacks) {
  InvokeInst &CB = *Plan.CB;
  Module &M = *CB.getModule();
  if (!Callbacks.UpdateCallSite(static_cast<int64_t>(Plan.StatepointID),
                                Plan.OptInfo.isStatic()
                                    ? jeandle::StaticCall
                                    : jeandle::OptVirtualCall,
                                /*NeedAttached=*/false, Plan.OptInfo.Method))
    return false;

  // Virtual/interface calls need a speculative receiver type guard.
  Value *Receiver = CB.getArgOperand(0);
  JavaTypes.invalidateForCFGChange(CB);
  BasicBlock *CheckInstanceofFail = insertCheckInstanceOf(
      CB, Receiver, Plan.OptInfo.constraint(), Plan.Prefix, &DTU);
  assert(CheckInstanceofFail && "failed to insert check_instanceof");

  IRBuilder<> BuilderFail(CheckInstanceofFail);
  buildDeoptimize(BuilderFail, M, Plan.OptInfo.deoptReason(),
                  jeandle::Deoptimization::Action_none,
                  *Plan.ReceiverGuardDeopt);

  // Retarget the invoke after the VM call-site record has been updated.
  updateStaticOptVirtualCallAttrs(
      CB, getPatchSize(&M, jeandle::Metadata::StaticCallPatchSize));
  Function *Target = getOrInsertJavaMethodFunction(
      M, Plan.OptInfo.MethodName, CB.getFunctionType(), Plan.OptInfo.Method,
      Plan.OptInfo.isAccessor());
  assert(Target && "CHA target was prevalidated");
  CB.setCalledFunction(Target);
  LLVM_DEBUG(dbgs() << "CHA: devirtualized " << CB << "\n");
  return true;
}

// Read-only analysis of one invoke. Returns a Skip plan for sites that need no
// rewrite or cannot be optimized.
CallSitePlan analyzeCallSite(InvokeInst &CB,
                             jeandle::JavaTypeAnalysisResult &JavaTypes,
                             const jeandle::VMCallbacks &Callbacks,
                             uintptr_t Caller) {
  // A java-attributed invoke is not necessarily a direct java call: legal IR
  // can attach the call-site attributes to an indirect callee or to a call
  // without a receiver argument. Every path below assumes a direct callee and
  // at least one operand, so bail here instead of dereferencing.
  Function *CalleeFn = CB.getCalledFunction();
  if (!CalleeFn || CB.arg_empty())
    return {};

  // linkTo* intrinsics need their MemberName operand removed and their invoke
  // rebuilt. _invokeBasic is optimized separately.
  if (CB.hasFnAttr(jeandle::Attribute::MhIntrinsicName)) {
    StringRef IntrinsicName =
        CB.getFnAttr(jeandle::Attribute::MhIntrinsicName).getValueAsString();
    if (IntrinsicName == "_invokeBasic") {
      if (auto Plan = planInvokeBasic(CB, Callbacks, Caller))
        return std::move(*Plan);
      return {};
    }
    if (auto Plan =
            planMhIntrinsic(CB, JavaTypes, Callbacks, Caller, IntrinsicName))
      return std::move(*Plan);
    return {};
  }
  if (auto Plan = planDevirtualize(CB, JavaTypes, Callbacks, Caller))
    return std::move(*Plan);
  return {};
}

bool commitCallSite(CallSitePlan &Plan, DomTreeUpdater &DTU,
                    jeandle::JavaTypeAnalysisResult &JavaTypes,
                    const jeandle::VMCallbacks &Callbacks,
                    SmallVectorImpl<InvokeInst *> &Deferred) {
  switch (Plan.Kind) {
  case CallSitePlan::Skip:
    return false;
  case CallSitePlan::Devirtualize:
    return commitDevirtualize(Plan, DTU, JavaTypes, Callbacks);
  case CallSitePlan::MethodHandle:
    return commitMhIntrinsic(Plan, DTU, JavaTypes, Callbacks, Deferred);
  case CallSitePlan::InvokeBasic:
    return commitInvokeBasic(Plan, JavaTypes, Callbacks);
  }
  llvm_unreachable("unknown call-site plan");
}

} // namespace

PreservedAnalyses CHADevirtualization::run(Function &F,
                                           FunctionAnalysisManager &FAM) {
  Module *M = F.getParent();
  if (!M->getNamedMetadata(jeandle::Metadata::JavaMethodCompilation))
    return PreservedAnalyses::all();
  if (!jeandle::isRootJavaMethodFunction(F))
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
  auto &JavaTypes = FAM.getResult<jeandle::JavaTypeAnalysis>(F);
  DomTreeUpdater DTU(DT, DomTreeUpdater::UpdateStrategy::Lazy);
  // The null-edge oracle needs LazyValueInfo, whose cached per-block lattice
  // goes stale when a rewrite splits blocks. Queries and rewrites are
  // therefore separated into epochs: phase one only queries every pending
  // site, and phase two commits the resulting plans. JavaTypeAnalysis owns
  // that oracle and clears LVI when its invalidation requires it.

  bool Changed = false;
  uintptr_t Caller = 0;
  getFunctionJavaMethod(F, Caller);

  // Epoch loop: the read epoch analyzes every pending site without modifying
  // the IR; the write epoch commits the collected plans. Invokes rebuilt by
  // the method-handle path need ordinary CHA refinement, so they become the
  // pending sites of the next epoch.
  SmallVector<InvokeInst *, 16> Sites;
  for (Instruction &I : instructions(F)) {
    if (auto *CB = dyn_cast<InvokeInst>(&I))
      Sites.push_back(CB);
  }

  SmallVector<InvokeInst *, 16> Deferred;
  while (!Sites.empty()) {
    SmallVector<CallSitePlan, 16> Plans;
    for (InvokeInst *CB : Sites) {
      CallSitePlan Plan = analyzeCallSite(*CB, JavaTypes, *Callbacks, Caller);
      if (Plan.Kind != CallSitePlan::Skip)
        Plans.push_back(std::move(Plan));
    }
    Sites.clear();
    Deferred.clear();

    for (CallSitePlan &Plan : Plans)
      Changed |= commitCallSite(Plan, DTU, JavaTypes, *Callbacks, Deferred);

    DTU.flush();
    // Every commit path notifies JavaTypes before mutating the IR, which
    // clears LVI for CFG-changing rewrites; a fresh read epoch therefore
    // never queries a stale lattice.
    Sites.append(Deferred.begin(), Deferred.end());
  }

  if (!Changed)
    return PreservedAnalyses::all();

  PreservedAnalyses PA;
  PA.preserve<DominatorTreeAnalysis>();
  PA.preserve<LazyValueAnalysis>();
  PA.preserve<jeandle::JavaTypeAnalysis>();
  return PA;
}
