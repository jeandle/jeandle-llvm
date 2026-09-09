//===- ProfileDevirtualization.cpp - Jeandle profile devirtualization ----===//
//
// Copyright (c) 2026, the Jeandle-LLVM Authors. All Rights Reserved.
//
// Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM
// Exceptions. See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//
//
// The VM callback owns receiver-profile policy and returns resolved target
// methods. This pass owns the IR rewrite: it inserts exact-klass guards,
// creates deopt or virtual fallback paths, and turns successful paths into
// optimized-virtual calls while keeping statepoint and dominator information
// consistent.
//
//===----------------------------------------------------------------------===//

#include "llvm/Transforms/Jeandle/ProfileDevirtualization.h"

#include "llvm/ADT/SmallVector.h"
#include "llvm/Analysis/DomTreeUpdater.h"
#include "llvm/IR/Attributes.h"
#include "llvm/IR/BasicBlock.h"
#include "llvm/IR/Dominators.h"
#include "llvm/IR/IRBuilder.h"
#include "llvm/IR/InstIterator.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/Jeandle/Attributes.h"
#include "llvm/IR/Jeandle/Metadata.h"
#include "llvm/IR/Jeandle/VMCallback.h"
#include "llvm/IR/Module.h"
#include "llvm/IR/ProfDataUtils.h"
#include "llvm/Support/CommandLine.h"
#include "llvm/Support/Debug.h"
#include "llvm/Transforms/Jeandle/JeandleTransformUtils.h"
#include "llvm/Transforms/Utils/BasicBlockUtils.h"

#include <algorithm>
#include <cstdint>
#include <optional>

#define DEBUG_TYPE "profile-devirtualization"

using namespace llvm;

static cl::opt<bool> EnableProfileDevirtInlining(
    "jeandle-enable-profile-devirt-inline", cl::init(true),
    cl::desc("Allow profile-devirtualized targets to be considered by the "
             "Jeandle inliner"));

namespace {

void setBranchWeights(BranchInst &Branch, uint64_t TakenCount,
                      uint64_t TotalCount) {
  SmallVector<uint64_t, 2> Counts = {
      std::max<uint64_t>(TakenCount, 1),
      std::max<uint64_t>(TotalCount > TakenCount ? TotalCount - TakenCount : 1,
                         1)};
  SmallVector<uint32_t, 2> Weights;
  if (*std::max_element(Counts.begin(), Counts.end()) > UINT32_MAX) {
    Weights = llvm::downscaleWeights(Counts);
  } else {
    Weights.assign(Counts.begin(), Counts.end());
  }
  for (uint32_t &Weight : Weights)
    Weight = std::max<uint32_t>(Weight, 1);
  llvm::setBranchWeights(Branch, Weights, /*IsExpected=*/false);
}

struct ExactReceiverCheckContext {
  Function *LoadKlass = nullptr;
  Function *CheckExactKlass = nullptr;
  PointerType *KlassType = nullptr;
};

ExactReceiverCheckContext getExactReceiverCheckContext(Instruction &Inst) {
  Module *M = Inst.getModule();
  Function *LoadKlass = M->getFunction("jeandle.load_klass");
  Function *CheckExactKlass = M->getFunction("jeandle.check_exact_klass");
  assert(LoadKlass && CheckExactKlass &&
         "exact receiver check intrinsics must be present");
  return {
      LoadKlass, CheckExactKlass,
      PointerType::get(Inst.getContext(), jeandle::AddrSpace::CHeapAddrSpace)};
}

CallInst *loadReceiverKlass(IRBuilder<> &Builder, Function *LoadKlass,
                            Value *Receiver, const Twine &Name) {
  CallInst *ActualKlass = Builder.CreateCall(LoadKlass, {Receiver}, Name);
  ActualKlass->setCallingConv(CallingConv::Hotspot_JIT);
  return ActualKlass;
}

CallInst *checkExactReceiverKlass(IRBuilder<> &Builder,
                                  const ExactReceiverCheckContext &Checks,
                                  Value *ActualKlass, uintptr_t ReceiverKlass,
                                  const Twine &Name) {
  Value *ExpectedKlass =
      Builder.CreateIntToPtr(Builder.getInt64(ReceiverKlass), Checks.KlassType);
  CallInst *IsExact = Builder.CreateCall(Checks.CheckExactKlass,
                                         {ExpectedKlass, ActualKlass}, Name);
  IsExact->setCallingConv(CallingConv::Hotspot_JIT);
  return IsExact;
}

BasicBlock *createProfileJoinBlock(InvokeInst &CB) {
  BasicBlock *HitBlock = CB.getParent();
  BasicBlock *OriginalNormalDest = CB.getNormalDest();
  BasicBlock *JoinBlock =
      BasicBlock::Create(CB.getContext(), CB.getName() + ".profile.devirt.join",
                         HitBlock->getParent(), OriginalNormalDest);
  BranchInst::Create(OriginalNormalDest, JoinBlock);

  for (PHINode &Phi : OriginalNormalDest->phis())
    for (unsigned I = 0, E = Phi.getNumIncomingValues(); I != E; ++I)
      if (Phi.getIncomingBlock(I) == HitBlock)
        Phi.setIncomingBlock(I, JoinBlock);
  CB.setNormalDest(JoinBlock);
  return JoinBlock;
}

void addInvokeUnwindEdges(InvokeInst &CB, BasicBlock *HitBlock,
                          ArrayRef<BasicBlock *> ExtraBlocks) {
  BasicBlock *UnwindDest = CB.getUnwindDest();

  for (PHINode &Phi : UnwindDest->phis()) {
    int HitIndex = Phi.getBasicBlockIndex(HitBlock);
    assert(HitIndex >= 0 && "unwind phi must contain the original invoke edge");
    Value *Incoming = Phi.getIncomingValue(HitIndex);

    for (BasicBlock *ExtraBlock : ExtraBlocks)
      Phi.addIncoming(Incoming, ExtraBlock);
  }
}

void mergeInvokeResults(InvokeInst &CB, BasicBlock *HitBlock,
                        BasicBlock *JoinBlock, Value *SecondValue,
                        BasicBlock *SecondBlock, Value *MissValue,
                        BasicBlock *MissBlock) {
  if (CB.getType()->isVoidTy() || CB.use_empty())
    return;

  unsigned NumIncoming = 1 + (SecondValue != nullptr) + (MissValue != nullptr);
  PHINode *Result = PHINode::Create(CB.getType(), NumIncoming,
                                    CB.getName() + ".profile.devirt",
                                    JoinBlock->getFirstInsertionPt());
  Result->addIncoming(&CB, HitBlock);
  if (SecondValue != nullptr)
    Result->addIncoming(SecondValue, SecondBlock);
  if (MissValue != nullptr)
    Result->addIncoming(MissValue, MissBlock);

  SmallVector<Use *, 8> Uses;
  for (Use &U : CB.uses())
    if (U.getUser() != Result)
      Uses.push_back(&U);
  for (Use *U : Uses)
    U->set(Result);
}

/// Clones a Java invoke onto a newly created path and gives the clone a unique
/// statepoint id. The original call-site attributes and deopt state are kept so
/// code generation can describe the same Java frame on every path.
InvokeInst *cloneInvokeWithFreshStatepoint(InvokeInst &CB,
                                           BasicBlock &InsertBlock,
                                           BasicBlock *NormalDest,
                                           int64_t NewStatepointID,
                                           bool MarkProfileMiss) {
  SmallVector<Value *, 8> Args(CB.args());
  SmallVector<OperandBundleDef, 4> Bundles;
  CB.getOperandBundlesAsDefs(Bundles);

  IRBuilder<> Builder(&InsertBlock);
  InvokeInst *Clone = Builder.CreateInvoke(CB.getCalledFunction(), NormalDest,
                                           CB.getUnwindDest(), Args, Bundles);
  Clone->setCallingConv(CB.getCallingConv());
  Clone->setAttributes(CB.getAttributes());
  Clone->copyMetadata(CB);
  if (MarkProfileMiss)
    Clone->addFnAttr(Attribute::get(
        CB.getContext(), jeandle::Attribute::ProfileDevirtualizationMiss));

  if (NewStatepointID < 0)
    reportInvalidStatepointID(CB, "ProfileDevirtualization",
                              "GetNewStatepointID returned a negative id");
  setStatepointID(*Clone, static_cast<uint64_t>(NewStatepointID));
  return Clone;
}

void createVirtualMissPath(InvokeInst &CB, BasicBlock *MissBlock,
                           int64_t MissStatepointID, DomTreeUpdater &DTU) {
  BasicBlock *HitBlock = CB.getParent();
  BasicBlock *OriginalNormalDest = CB.getNormalDest();
  BasicBlock *UnwindDest = CB.getUnwindDest();
  BasicBlock *JoinBlock = createProfileJoinBlock(CB);

  // Prevent a later refinement round from guarding this fallback again.
  InvokeInst *Miss = cloneInvokeWithFreshStatepoint(CB, *MissBlock, JoinBlock,
                                                    MissStatepointID,
                                                    /*MarkProfileMiss=*/true);

  addInvokeUnwindEdges(CB, HitBlock, {MissBlock});
  mergeInvokeResults(CB, HitBlock, JoinBlock, nullptr, nullptr, Miss,
                     MissBlock);

  DTU.applyUpdates({{DominatorTree::Delete, HitBlock, OriginalNormalDest},
                    {DominatorTree::Insert, HitBlock, JoinBlock},
                    {DominatorTree::Insert, MissBlock, JoinBlock},
                    {DominatorTree::Insert, MissBlock, UnwindDest},
                    {DominatorTree::Insert, JoinBlock, OriginalNormalDest}});
  DTU.flush();
}

BasicBlock *insertExactReceiverCheck(Instruction &Inst, Value *Receiver,
                                     uintptr_t ReceiverKlass,
                                     uint64_t ProfileCount,
                                     uint64_t ProfileTotalCount,
                                     const StringRef &Prefix,
                                     DomTreeUpdater &DTU) {
  assert(Receiver->getType()->isPointerTy() && "Receiver must be a pointer");

  BasicBlock *BB = Inst.getParent();
  ExactReceiverCheckContext Checks = getExactReceiverCheckContext(Inst);

  LLVMContext &Context = Inst.getContext();
  BasicBlock *CheckPass = SplitBlock(BB, &Inst, &DTU, nullptr, nullptr,
                                     Prefix + "_exact_receiver_pass");
  BasicBlock *CheckFail = BasicBlock::Create(
      Context, Prefix + "_exact_receiver_fail", BB->getParent(), CheckPass);

  BB->getTerminator()->eraseFromParent();
  IRBuilder<> Builder(BB);

  CallInst *ActualKlass = loadReceiverKlass(Builder, Checks.LoadKlass, Receiver,
                                            Prefix + "_actual_klass");
  CallInst *IsProfiledReceiver = checkExactReceiverKlass(
      Builder, Checks, ActualKlass, ReceiverKlass, Prefix + "_is_exact_0");
  BranchInst *Guard =
      Builder.CreateCondBr(IsProfiledReceiver, CheckPass, CheckFail);
  setBranchWeights(*Guard, ProfileCount, ProfileTotalCount);

  DTU.applyUpdates({{DominatorTree::Insert, BB, CheckFail}});
  DTU.flush();
  return CheckFail;
}

struct BimorphicCheckBlocks {
  BasicBlock *SecondHitBlock = nullptr;
  BasicBlock *MissBlock = nullptr;
};

struct ProfileCallSiteIDs {
  int64_t Original = -1;
  int64_t Second = -1;
  int64_t Miss = -1;
};

std::optional<ProfileCallSiteIDs>
prepareCallSites(const jeandle::VMCallbacks &Callbacks, int64_t Original,
                 bool IsBimorphic, bool CreateVirtualMiss) {
  ProfileCallSiteIDs IDs;
  IDs.Original = Original;

  if (IsBimorphic) {
    IDs.Second = Callbacks.GetNewStatepointID(Original);
    if (IDs.Second < 0)
      return std::nullopt;
  }
  if (CreateVirtualMiss) {
    IDs.Miss = Callbacks.GetNewStatepointID(Original);
    if (IDs.Miss < 0)
      return std::nullopt;
  }

  if ((IsBimorphic && !Callbacks.UpdateToStaticOptVirtualCall(IDs.Second)) ||
      !Callbacks.UpdateToStaticOptVirtualCall(IDs.Original))
    return std::nullopt;
  return IDs;
}

BimorphicCheckBlocks insertBimorphicReceiverChecks(
    Instruction &Inst, Value *Receiver, uintptr_t ReceiverKlass,
    uint64_t ProfileCount, uintptr_t ReceiverKlass2, uint64_t ProfileCount2,
    uint64_t ProfileTotalCount, const StringRef &Prefix, DomTreeUpdater &DTU) {
  assert(Receiver->getType()->isPointerTy() && "Receiver must be a pointer");
  assert(ReceiverKlass2 != 0 && "second receiver must be present");

  BasicBlock *BB = Inst.getParent();
  ExactReceiverCheckContext Checks = getExactReceiverCheckContext(Inst);

  LLVMContext &Context = Inst.getContext();
  BasicBlock *FirstHitBlock = SplitBlock(BB, &Inst, &DTU, nullptr, nullptr,
                                         Prefix + "_exact_receiver_0_pass");
  BasicBlock *SecondCheckBlock =
      BasicBlock::Create(Context, Prefix + "_exact_receiver_1_check",
                         BB->getParent(), FirstHitBlock);
  BasicBlock *SecondHitBlock =
      BasicBlock::Create(Context, Prefix + "_exact_receiver_1_pass",
                         BB->getParent(), FirstHitBlock);
  BasicBlock *MissBlock = BasicBlock::Create(
      Context, Prefix + "_exact_receiver_fail", BB->getParent(), FirstHitBlock);

  BB->getTerminator()->eraseFromParent();
  IRBuilder<> Builder(BB);
  CallInst *ActualKlass = loadReceiverKlass(Builder, Checks.LoadKlass, Receiver,
                                            Prefix + "_actual_klass");
  CallInst *IsReceiver = checkExactReceiverKlass(
      Builder, Checks, ActualKlass, ReceiverKlass, Prefix + "_is_exact_0");
  BranchInst *FirstGuard =
      Builder.CreateCondBr(IsReceiver, FirstHitBlock, SecondCheckBlock);
  setBranchWeights(*FirstGuard, ProfileCount, ProfileTotalCount);

  IRBuilder<> SecondBuilder(SecondCheckBlock);
  CallInst *IsReceiver2 =
      checkExactReceiverKlass(SecondBuilder, Checks, ActualKlass,
                              ReceiverKlass2, Prefix + "_is_exact_1");
  BranchInst *SecondGuard =
      SecondBuilder.CreateCondBr(IsReceiver2, SecondHitBlock, MissBlock);
  uint64_t RemainingCount =
      ProfileTotalCount > ProfileCount ? ProfileTotalCount - ProfileCount : 1;
  setBranchWeights(*SecondGuard, ProfileCount2, RemainingCount);

  DTU.applyUpdates({{DominatorTree::Insert, BB, SecondCheckBlock},
                    {DominatorTree::Insert, SecondCheckBlock, SecondHitBlock},
                    {DominatorTree::Insert, SecondCheckBlock, MissBlock}});
  DTU.flush();
  return {SecondHitBlock, MissBlock};
}

InvokeInst *
createBimorphicCallPaths(InvokeInst &CB, const BimorphicCheckBlocks &Blocks,
                         int64_t SecondStatepointID, int64_t MissStatepointID,
                         bool CreateVirtualMiss, DomTreeUpdater &DTU) {
  assert(Blocks.SecondHitBlock && Blocks.MissBlock &&
         "bimorphic receiver checks must be present");
  BasicBlock *FirstHitBlock = CB.getParent();
  BasicBlock *OriginalNormalDest = CB.getNormalDest();
  BasicBlock *UnwindDest = CB.getUnwindDest();
  BasicBlock *JoinBlock = createProfileJoinBlock(CB);

  InvokeInst *SecondHitCall = cloneInvokeWithFreshStatepoint(
      CB, *Blocks.SecondHitBlock, JoinBlock, SecondStatepointID,
      /*MarkProfileMiss=*/false);

  InvokeInst *MissCall = nullptr;
  if (CreateVirtualMiss)
    MissCall = cloneInvokeWithFreshStatepoint(CB, *Blocks.MissBlock, JoinBlock,
                                              MissStatepointID,
                                              /*MarkProfileMiss=*/true);

  if (MissCall) {
    addInvokeUnwindEdges(CB, FirstHitBlock,
                         {Blocks.SecondHitBlock, Blocks.MissBlock});
  } else {
    addInvokeUnwindEdges(CB, FirstHitBlock, {Blocks.SecondHitBlock});
  }
  mergeInvokeResults(CB, FirstHitBlock, JoinBlock, SecondHitCall,
                     Blocks.SecondHitBlock, MissCall, Blocks.MissBlock);

  SmallVector<DominatorTree::UpdateType, 8> Updates = {
      {DominatorTree::Delete, FirstHitBlock, OriginalNormalDest},
      {DominatorTree::Insert, FirstHitBlock, JoinBlock},
      {DominatorTree::Insert, Blocks.SecondHitBlock, JoinBlock},
      {DominatorTree::Insert, Blocks.SecondHitBlock, UnwindDest},
      {DominatorTree::Insert, JoinBlock, OriginalNormalDest}};
  if (MissCall) {
    Updates.push_back({DominatorTree::Insert, Blocks.MissBlock, JoinBlock});
    Updates.push_back({DominatorTree::Insert, Blocks.MissBlock, UnwindDest});
  }
  DTU.applyUpdates(Updates);
  DTU.flush();
  return SecondHitCall;
}

bool optimizeCallSite(InvokeInst &CB, DomTreeUpdater &DTU,
                      const jeandle::VMCallbacks &Callbacks, int PatchSize,
                      uintptr_t RootCaller) {
  // Do not recursively guard a fallback created by an earlier round.
  if (CB.getAttributes().hasFnAttr(
          jeandle::Attribute::ProfileDevirtualizationMiss))
    return false;

  if (CB.hasFnAttr(jeandle::Attribute::MonomorphicTarget))
    return false;

  auto CallSite = getJavaVirtualCallSite(CB);
  if (!CallSite)
    return false;

  uintptr_t ScopeCaller = getCurrentDeoptMethod(CB, RootCaller);
  int BCI = getCurrentDeoptBCI(CB);
  jeandle::ProfileDevirtualizationInfo OptInfo(
      Callbacks.GetProfileDevirtualizationInfo(
          ScopeCaller, CallSite->CalleeMethod, CallSite->DeclaredHolder, BCI,
          static_cast<int>(CallSite->InvokeKind)));
  if (!OptInfo.isValid())
    return false;

  // Keep profile devirtualization independent from the inliner. A guarded
  // direct target remains valid even if a later inline round declines it.
  bool IsBimorphic = OptInfo.isBimorphic();
  Module &M = *CB.getModule();
  FunctionType *CallType = CB.getFunctionType();
  if (!canGetOrInsertJavaMethodFunction(M, OptInfo.Target.MethodName, CallType,
                                        OptInfo.Target.Method) ||
      (IsBimorphic &&
       !canGetOrInsertJavaMethodFunction(M, OptInfo.Target2.MethodName,
                                         CallType, OptInfo.Target2.Method)) ||
      (IsBimorphic && OptInfo.Target.MethodName == OptInfo.Target2.MethodName &&
       OptInfo.Target.Method != OptInfo.Target2.Method))
    return false;

  std::optional<OperandBundleDef> PreCallDeopt;
  if (OptInfo.DeoptimizeOnMiss) {
    PreCallDeopt = createPreCallDeoptBundle(CB);
    if (!PreCallDeopt)
      return false;
  }

  bool CreateVirtualMiss = !OptInfo.DeoptimizeOnMiss;
  std::optional<ProfileCallSiteIDs> IDs =
      prepareCallSites(Callbacks, static_cast<int64_t>(CallSite->StatepointID),
                       IsBimorphic, CreateVirtualMiss);
  if (!IDs)
    return false;

  Function *Func = getOrInsertJavaMethodFunction(
      M, OptInfo.Target.MethodName, CallType, OptInfo.Target.Method,
      OptInfo.isAccessor());
  assert(Func && "profile target was prevalidated");
  Function *Func2 = nullptr;
  if (IsBimorphic) {
    Func2 = getOrInsertJavaMethodFunction(M, OptInfo.Target2.MethodName,
                                          CallType, OptInfo.Target2.Method,
                                          OptInfo.isAccessor2());
    assert(Func2 && "second profile target was prevalidated");
  }

  std::string Prefix = "bci_profile_devirt_" + std::to_string(BCI);

  InvokeInst *SecondHitCall = nullptr;
  if (IsBimorphic) {
    BimorphicCheckBlocks Blocks = insertBimorphicReceiverChecks(
        CB, CallSite->Receiver, OptInfo.Target.ReceiverKlass,
        OptInfo.Target.Count, OptInfo.Target2.ReceiverKlass,
        OptInfo.Target2.Count, OptInfo.TotalCount, Prefix, DTU);
    SecondHitCall = createBimorphicCallPaths(CB, Blocks, IDs->Second, IDs->Miss,
                                             CreateVirtualMiss, DTU);
    if (OptInfo.DeoptimizeOnMiss) {
      IRBuilder<> MissBuilder(Blocks.MissBlock);
      buildDeoptimize(MissBuilder, *CB.getModule(), OptInfo.deoptReason(),
                      jeandle::Deoptimization::Action_maybe_recompile,
                      *PreCallDeopt);
    }
  } else {
    BasicBlock *MissBlock = insertExactReceiverCheck(
        CB, CallSite->Receiver, OptInfo.Target.ReceiverKlass,
        OptInfo.Target.Count, OptInfo.TotalCount, Prefix, DTU);
    if (OptInfo.DeoptimizeOnMiss) {
      IRBuilder<> MissBuilder(MissBlock);
      buildDeoptimize(MissBuilder, *CB.getModule(), OptInfo.deoptReason(),
                      jeandle::Deoptimization::Action_maybe_recompile,
                      *PreCallDeopt);
    } else {
      createVirtualMissPath(CB, MissBlock, IDs->Miss, DTU);
    }
  }

  updateStaticOptVirtualCallAttrs(CB, PatchSize, !EnableProfileDevirtInlining);
  CB.setCalledFunction(Func);

  if (SecondHitCall) {
    updateStaticOptVirtualCallAttrs(*SecondHitCall, PatchSize,
                                    !EnableProfileDevirtInlining);
    SecondHitCall->setCalledFunction(Func2);
  }
  LLVM_DEBUG(dbgs() << "Profile devirtualized " << CB;
             if (SecondHitCall) dbgs() << " and " << *SecondHitCall;
             dbgs() << "\n";);
  DTU.flush();
  return true;
}

} // namespace

PreservedAnalyses ProfileDevirtualization::run(Function &F,
                                               FunctionAnalysisManager &FAM) {
  Module *M = F.getParent();
  if (!M->getNamedMetadata(jeandle::Metadata::JavaMethodCompilation))
    return PreservedAnalyses::all();
  if (!jeandle::isRootJavaMethodFunction(F))
    return PreservedAnalyses::all();

  const jeandle::VMCallbacks *Callbacks = jeandle::getVMCallbacks();
  assert(Callbacks && Callbacks->GetProfileDevirtualizationInfo &&
         Callbacks->GetNewStatepointID &&
         Callbacks->UpdateToStaticOptVirtualCall && "VMCallbacks must be set");

  uintptr_t Caller = 0;
  if (!getFunctionJavaMethod(F, Caller))
    return PreservedAnalyses::all();

  DominatorTree &DT = FAM.getResult<DominatorTreeAnalysis>(F);
  DomTreeUpdater DTU(DT, DomTreeUpdater::UpdateStrategy::Lazy);

  SmallVector<InvokeInst *, 16> Calls;
  for (Instruction &I : instructions(F)) {
    if (auto *CB = dyn_cast<InvokeInst>(&I))
      Calls.push_back(CB);
  }

  bool Changed = false;
  int PatchSize = getStaticCallPatchSize(*F.getParent());
  for (InvokeInst *CB : Calls)
    Changed |= optimizeCallSite(*CB, DTU, *Callbacks, PatchSize, Caller);

  if (!Changed)
    return PreservedAnalyses::all();

  PreservedAnalyses PA;
  PA.preserve<DominatorTreeAnalysis>();
  return PA;
}
