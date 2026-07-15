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
#include "llvm/Analysis/BlockFrequencyInfo.h"
#include "llvm/Analysis/BranchProbabilityInfo.h"
#include "llvm/Analysis/DomTreeUpdater.h"
#include "llvm/Analysis/DominanceFrontier.h"
#include "llvm/Analysis/LoopInfo.h"
#include "llvm/Analysis/PostDominators.h"
#include "llvm/IR/Attributes.h"
#include "llvm/IR/BasicBlock.h"
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
#include "llvm/IR/Jeandle/Metadata.h"
#include "llvm/IR/Jeandle/VMCallback.h"
#include "llvm/IR/Metadata.h"
#include "llvm/IR/Module.h"
#include "llvm/Support/Debug.h"
#include "llvm/Transforms/Jeandle/JeandleTransformUtils.h"
#include "llvm/Transforms/Utils/BasicBlockUtils.h"

#include <cstdint>
#include <optional>

#define DEBUG_TYPE "cha-devirtualization"

using namespace llvm;

namespace {

int getDeoptBCI(const InvokeInst &CB) {
  std::optional<OperandBundleUse> Deopt =
      CB.getOperandBundle(LLVMContext::OB_deopt);
  auto *BCI = dyn_cast<ConstantInt>(Deopt->Inputs[0].get());
  return static_cast<int>(BCI->getSExtValue());
}

int getPatchSize(const Module *M) {
  NamedMDNode *NMD =
      M->getNamedMetadata(jeandle::Metadata::StaticCallPatchSize);
  assert(NMD && NMD->getNumOperands() == 1 && "expected patch size metadata");
  MDNode *PatchNode = NMD->getOperand(0);
  assert(PatchNode && PatchNode->getNumOperands() == 1 && "must be");
  return mdconst::extract<ConstantInt>(PatchNode->getOperand(0))
      ->getSExtValue();
}

void updateStaticOptVirtualCallAttrs(InvokeInst &CB, int PatchSize) {
  CB.removeFnAttr(jeandle::Attribute::StatepointNumPatchBytes);
  CB.addFnAttr(Attribute::get(CB.getContext(),
                              jeandle::Attribute::StatepointNumPatchBytes,
                              std::to_string(PatchSize)));
  CB.addFnAttr(
      Attribute::get(CB.getContext(), jeandle::Attribute::MonomorphicTarget));
}

bool optimizeCallSite(InvokeInst &CB, DominatorTree &DT, DomTreeUpdater &DTU,
                      const jeandle::VMCallbacks &Callbacks, uintptr_t Caller,
                      int PatchSize) {
  // quick check if this is a java virtual call.
  if (CB.hasFnAttr(jeandle::Attribute::MonomorphicTarget))
    return false;

  Attribute BC = CB.getFnAttr(jeandle::Attribute::Bytecode);
  if (!checkStringAttr(BC))
    return false;

  StringRef Bytecode = BC.getValueAsString();
  jeandle::InvokeType InvokeKind = jeandle::getInvokeType(Bytecode);
  // CHADevirtualization can only handles invokevirtual and invokeinterface
  // calls now.
  if (InvokeKind != jeandle::InvokeVirtual &&
      InvokeKind != jeandle::InvokeInterface)
    return false;

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
  assert(Callee != 0 && Holder != 0 &&
         (InvokeKind == jeandle::InvokeVirtual ||
          InvokeKind == jeandle::InvokeInterface) &&
         "should be a java call");

  jeandle::JavaType ReceiverType = jeandle::getJavaType(Receiver, &DT, &CB);

  auto CHAOptInfo = jeandle::CHAOptInfo::decode(
      Callbacks.GetCHAOptInfo(Caller, Callee, Holder, ReceiverType.Klass,
                              ReceiverType.Exact, InvokeKind));
  if (CHAOptInfo.Constraint == 0)
    return false;

  int BCI = getDeoptBCI(CB);
  std::string Prefix = "bci_cha_" + std::to_string(BCI);

  std::optional<OperandBundleDef> PreCallDeopt = createPreCallDeoptBundle(CB);
  if (!PreCallDeopt)
    return false;

  BasicBlock *CheckInstanceofFail =
      insertCheckInstanceOf(CB, Receiver, CHAOptInfo.Constraint, Prefix, &DTU);
  assert(CheckInstanceofFail && "failed to insert check_instanceof");

  IRBuilder<> BuilderFail(CheckInstanceofFail);
  buildDeoptimize(BuilderFail, *CB.getModule(), CHAOptInfo.DeoptReason,
                  jeandle::Deoptimization::Action_none, *PreCallDeopt);

  updateStaticOptVirtualCallAttrs(CB, PatchSize);
  CB.setCalledFunction(CB.getModule()->getOrInsertFunction(
      CHAOptInfo.MethodName, CB.getFunctionType()));
  llvm::Function *Func = CB.getCalledFunction();
  Func->setCallingConv(llvm::CallingConv::Hotspot_JIT);
  Func->setGC(llvm::jeandle::JeandleGC);
  Func->addFnAttr(llvm::Attribute::get(CB.getContext(),
                                       llvm::jeandle::Attribute::JavaMethod,
                                       std::to_string(CHAOptInfo.Method)));

  Callbacks.UpdateToStaticOptVirtualCall(static_cast<int64_t>(Id));
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

  const jeandle::VMCallbacks *Callbacks = jeandle::getVMCallbacks();
  assert(Callbacks && Callbacks->IsSubtype && Callbacks->GetCommonSuperKlass &&
         Callbacks->GetFieldType && Callbacks->IsInterface &&
         Callbacks->IsObjectKlass && Callbacks->IsEffectivelyFinal &&
         Callbacks->GetCHAOptInfo && Callbacks->UpdateToStaticOptVirtualCall &&
         "VMCallbacks must be set");

  DominatorTree &DT = FAM.getResult<DominatorTreeAnalysis>(F);
  DomTreeUpdater DTU(DT, DomTreeUpdater::UpdateStrategy::Lazy);

  SmallVector<InvokeInst *, 16> Calls;
  for (Instruction &I : instructions(F)) {
    if (auto *CB = dyn_cast<InvokeInst>(&I))
      Calls.push_back(CB);
  }

  bool Changed = false;
  uintptr_t Caller = 0;
  PatchSize = PatchSize == 0 ? getPatchSize(F.getParent()) : PatchSize;
  getFunctionJavaMethod(F, Caller);
  for (InvokeInst *CB : Calls)
    Changed |= optimizeCallSite(*CB, DT, DTU, *Callbacks, Caller, PatchSize);

  if (!Changed)
    return PreservedAnalyses::all();

  PreservedAnalyses PA;
  PA.preserve<DominatorTreeAnalysis>();
  return PA;
}
