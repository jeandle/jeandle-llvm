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

// Read the VM-provided size of the stub patch for a given call kind.
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
  CB.removeFnAttr(jeandle::Attribute::StatepointNumPatchBytes);
  CB.addFnAttr(Attribute::get(CB.getContext(),
                              jeandle::Attribute::StatepointNumPatchBytes,
                              std::to_string(PatchSize)));
  CB.addFnAttr(
      Attribute::get(CB.getContext(), jeandle::Attribute::MonomorphicTarget));
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

// Intersect an oop's inferred type with the target signature and materialize
// an assume only when the intersection provides additional type information.
Value *tryNarrowJavaObjType(Value *Receiver, JavaType HolderType,
                            DominatorTree &DT, InvokeInst &CB) {
  JavaType ReceiverType = jeandle::getJavaType(Receiver, &DT, &CB);
  JavaType CastedReceiverType =
      jeandle::typeIntersect(HolderType, ReceiverType);
  if (CastedReceiverType.Klass == 0) {
    LLVM_DEBUG(dbgs() << "Receiver argument type mismatch.\n");
    return nullptr;
  }
  if (CastedReceiverType != ReceiverType) {
    return insertJavaTypeAssume(Receiver, CastedReceiverType, &CB);
  }
  return Receiver;
}

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

// Rebuild a linkTo* invoke without its trailing MemberName operand. Preserve
// its control-flow edges and operand bundles while attaching the resolved
// target, bytecode kind, patch size, and receiver attributes.
InvokeInst *createNewCB(InvokeInst &CB, bool IsMonomorphicTarget, int PatchSize,
                        FunctionType *FuncType, uintptr_t Method,
                        const StringRef &MethodName,
                        const StringRef &ByteCodeName, uintptr_t Holder,
                        uint64_t Id, jeandle::CHADestKind DestKind,
                        bool IsAccessor) {
  SmallVector<OperandBundleDef, 4> Bundles;
  CB.getOperandBundlesAsDefs(Bundles);
  SmallVector<Value *, 8> NewArgs;
  for (unsigned I = 0, E = CB.arg_size() - 1; I != E; ++I) {
    NewArgs.push_back(CB.getArgOperand(I));
  }

  Module *M = CB.getModule();
  auto *NewCB =
      InvokeInst::Create(getOrInsertJavaMethodFunction(*M, MethodName, FuncType,
                                                       Method, IsAccessor),
                         CB.getNormalDest(), CB.getUnwindDest(), NewArgs,
                         Bundles, CB.getName(), CB.getIterator());
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

// Resolve a linkTo* intrinsic through its constant MemberName and rebuild the
// invoke with the target's Java signature. _invokeBasic follows the regular
// CHA path below because it does not require call reconstruction.
InvokeInst *optimizeMhIntrinsic(InvokeInst &CB, Function &F, DominatorTree &DT,
                                DomTreeUpdater &DTU,
                                const jeandle::VMCallbacks &Callbacks,
                                uintptr_t Caller,
                                const StringRef &IntrinsicName) {
  assert(IntrinsicName != "_invokeBasic" &&
         "_invokeBasic is treated in normal path.");
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

  // Collect the identities needed to resolve this particular call site.
  uintptr_t Callee = 0;
  uintptr_t Holder = 0;
  uint64_t Id = 0;
  getFunctionJavaMethod(*CB.getCalledFunction(), Callee);
  getUIntPtrFnAttr(CB, jeandle::Attribute::DeclaredHolder, Holder);
  getUIntFnAttr(CB, jeandle::Attribute::StatepointID, Id);
  assert(Id >= 0 && Id <= 0xffffffff && "must be 32 bits.");
  assert(Callee != 0 && Holder != 0 && "should be a java call");

  // The final argument for _invokeBasic intrinsic is the MemberName oop handle.
  // Optimization is only safe when the handle can be identified as a constant.
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

  // Reconstruct the target signature and tentatively narrow reference
  // operands to the declared Java types returned by the callback.
  const int IsStatic = CHAOptInfo.isStatic();
  DenseMap<int, Value *> JavaTypeAssumeCB;
  llvm::SmallVector<llvm::Type *> ArgTypes;
  bool NarrowSuccess = true;
  if (!IsStatic) {
    Value *Receiver = CB.getArgOperand(0);
    if (jeandle::isJavaOopType(Receiver->getType())) {
      JavaType HolderType = {
          Callbacks.GetSignatureAccessingKlass(CHAOptInfo.Method), false};
      if (HolderType.Klass != 0) {
        Value *CastedReceiver =
            tryNarrowJavaObjType(Receiver, HolderType, DT, CB);
        if (CastedReceiver != Receiver) {
          JavaTypeAssumeCB[0] = CastedReceiver;
          NarrowSuccess &= CastedReceiver != nullptr;
        }
      }
    }
    ArgTypes.push_back(java2llvm(jeandle::T_OBJECT, CB.getContext()));
  }
  for (int I = 0; NarrowSuccess && I < CHAOptInfo.argsNum(); ++I) {
    Value *Op = CB.getArgOperand(I + !IsStatic);
    if (jeandle::isJavaOopType(Op->getType())) {
      JavaType ArgsDeclareType = {
          Callbacks.GetSignatureArgTypeKlass(CHAOptInfo.Method, I), false};
      if (ArgsDeclareType.Klass != 0) {
        Value *CastedReceiver =
            tryNarrowJavaObjType(Op, ArgsDeclareType, DT, CB);
        if (CastedReceiver != Op) {
          JavaTypeAssumeCB[I + !IsStatic] = CastedReceiver;
          NarrowSuccess &= CastedReceiver != nullptr;
        }
      }
    }
    ArgTypes.push_back(
        java2llvm(static_cast<jeandle::HotspotBasicType>(
                      Callbacks.GetSignatureArgType(CHAOptInfo.Method, I)),
                  CB.getContext()));
  }

  // Select the runtime call-site representation and its patching contract.
  // Virtual/interface targets that cannot be statically bound remain dynamic;
  // all other linkTo* variants use a patchable static sequence.
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
  } else if (IntrinsicName == "_linkToSpecial") {
    DestKind = jeandle::OptVirtualCall;
    PatchSize =
        getPatchSize(CB.getModule(), jeandle::Metadata::StaticCallPatchSize);
  } else {
    DestKind = jeandle::StaticCall;
    PatchSize =
        getPatchSize(CB.getModule(), jeandle::Metadata::StaticCallPatchSize);
  }

  // Do not commit any speculative type assumptions unless all arguments were
  // compatible and the VM accepted the new call-site representation.
  if (!NarrowSuccess ||
      !Callbacks.UpdateCallSite(static_cast<int64_t>(Id), DestKind, true,
                                CHAOptInfo.Method)) {
    for (auto &[_, Value] : JavaTypeAssumeCB) {
      if (CallInst *Inst = dyn_cast_or_null<CallInst>(Value)) {
        Inst->eraseFromParent();
      }
    }
    return nullptr;
  }

  // Commit the narrowed operands only after validation and construct the
  // resolved target's LLVM function type.
  Type *RetType =
      java2llvm(static_cast<jeandle::HotspotBasicType>(
                    Callbacks.GetSignatureArgType(CHAOptInfo.Method, -1)),
                CB.getContext());
  for (auto &[ArgIdx, AssumeCB] : JavaTypeAssumeCB) {
    CB.setArgOperand(ArgIdx, AssumeCB);
  }
  FunctionType *FuncType = FunctionType::get(RetType, ArgTypes, false);
  StringRef NewBCName = getByteCodeName(IntrinsicName);

  // linkTo* performs the receiver null check implicitly. Preserve that
  // behavior before replacing it with a direct Java invoke.
  if (hasReceiver(NewBCName)) {
    std::optional<OperandBundleDef> PreCallDeopt = createPreCallDeoptBundle(CB);
    if (!PreCallDeopt)
      return nullptr;
    int BCI = getCurrentDeoptBCI(CB);
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
                     CHAOptInfo.holder(), Id, DestKind,
                     CHAOptInfo.isAccessor());
}

bool optimizeCallSite(InvokeInst &CB, Function &F, DominatorTree &DT,
                      DomTreeUpdater &DTU,
                      const jeandle::VMCallbacks &Callbacks, uintptr_t Caller) {
  using jeandle::JavaType;

  // linkTo* intrinsics first need their MemberName operand removed and their
  // invoke rebuilt. Feed the rebuilt call back through this path so ordinary
  // CHA refinement can run on it as well. _invokeBasic is handled in place.
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
        optimizeCallSite(*NewCB, F, DT, DTU, Callbacks, Caller);
        return true;
      }
      return false;
    }
    IsInvokeBasic = true;
  }

  Module *M = CB.getModule();

  // Calls already known to have a monomorphic target need no further work.
  // _invokeBasic is the exception because its constant oop handle still needs
  // to be resolved to the underlying Java method.
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
    // _invokeBasic can be resolved only when its MethodHandle receiver is a
    // known VM oop handle.
    OopId = getOperandOopHandleLoadId(CB, 0);
    if (OopId == -1) {
      LLVM_DEBUG(dbgs() << "optimize_method_handle_intrinsic: _invokeBasic: "
                        << "receiver is not constant\n");
      return false;
    }
  }

  uintptr_t ScopeCaller = getCurrentDeoptMethod(CB, Caller);
  auto CHAOptInfo = jeandle::CHAOptInfo::decode(
      Callbacks.GetCHAOptInfo(ScopeCaller, Callee, Holder, ReceiverType.Klass,
                              ReceiverType.Exact, InvokeKind, OopId));
  if (CHAOptInfo.constraint() == 0 ||
      !Callbacks.UpdateCallSite(static_cast<int64_t>(Id),
                                CHAOptInfo.isStatic() ? jeandle::StaticCall
                                                      : jeandle::OptVirtualCall,
                                IsInvokeBasic, CHAOptInfo.Method)) {
    return false;
  }

  int BCI = getCurrentDeoptBCI(CB);
  std::string Prefix = "cha_bci_" + std::to_string(BCI);

  // Ordinary virtual/interface calls need a speculative type guard. A
  // constant _invokeBasic receiver already identifies its target, so no
  // additional receiver guard is necessary.
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

  // Retarget the invoke after the VM call-site record has been updated.
  updateStaticOptVirtualCallAttrs(
      CB, getPatchSize(M, jeandle::Metadata::StaticCallPatchSize));
  CB.setCalledFunction(getOrInsertJavaMethodFunction(
      *CB.getModule(), CHAOptInfo.MethodName, CB.getFunctionType(),
      CHAOptInfo.Method, CHAOptInfo.isAccessor()));

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
  DomTreeUpdater DTU(DT, DomTreeUpdater::UpdateStrategy::Lazy);

  // Snapshot invoke instructions because successful rewrites can replace and
  // erase call sites while the pass is running.
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
