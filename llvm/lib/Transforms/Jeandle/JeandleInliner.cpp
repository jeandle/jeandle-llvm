//===- JeandleInliner.cpp - Jeandle method inliner ------------------------===//
//
// Copyright (c) 2026, the Jeandle-LLVM Authors. All Rights Reserved.
//
// Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM
// Exceptions. See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//
//
// This file implements the single-round JeandleInliner pass for Jeandle JVM
// JIT. Unlike the standard InlinerPass which operates on the LazyCallGraph/SCC,
// the current inline step walks call sites in the module directly.
//
// JeandleInliner has two entry points by design. run() is the standard LLVM
// pass entry point for standalone use, while runInlineRound() returns
// InlineRoundResult so JeandleInlineDriver can use it as an iterative driver
// step and observe whether the round changed IR through PreservedAnalyses and
// whether new call sites were exposed.
//
// Algorithm:
//   1. Collect all call sites in the single root Jeandle Java method where the
//      callee is a Jeandle Java method (identified by the
//      llvm::jeandle::Attribute::JavaMethod function attribute) and the call
//      site has the llvm::jeandle::Attribute::MonomorphicTarget attribute.
//      In accessor-only mode, the callee must also have the
//      llvm::jeandle::Attribute::JavaAccessorMethod function attribute.
//   2. For each call site, ask VMCallbacks::IsOkToInline whether to inline.
//   3. If the callee is a declaration, call VMCallbacks::GetInlineCalleeIR to
//      obtain its IR definition.
//   4. Inline the call site using InlineFunction.
//   5. Any new call sites exposed by inlining are tagged with a new inline
//      scope ID. Already-monomorphic call sites are also added to the current
//      worklist.
//   6. Repeat until the worklist is empty.
//
// General inline policy, including any depth limit, is decided by the VM
// callbacks. LLVM still tracks InlineScopeID to identify the current inline
// scope for VM callback decisions. The root method is never inlined as a
// callee because root/caller IR and callee IR handle unwind differently: the
// root emits real unwind operations, while an inlined callee forwards unwind
// edges to the caller's landingpad.
//
// Only call sites proven monomorphic by earlier analysis are annotated with
// llvm::jeandle::Attribute::MonomorphicTarget. This is true both in the
// original module and for call sites exposed after inlining.
// JeandleInlineDriver is the extension point for devirtualization refinement
// between inline rounds so newly exposed call sites can be specialized before
// they are reconsidered.
//
//===----------------------------------------------------------------------===//

#include "llvm/Transforms/Jeandle/JeandleInliner.h"

#include "llvm/ADT/DenseMap.h"
#include "llvm/ADT/STLExtras.h"
#include "llvm/ADT/SmallPtrSet.h"
#include "llvm/ADT/SmallVector.h"
#include "llvm/Analysis/AliasAnalysis.h"
#include "llvm/Analysis/AssumptionCache.h"
#include "llvm/Analysis/InlineCost.h"
#include "llvm/Analysis/OptimizationRemarkEmitter.h"
#include "llvm/Analysis/ProfileSummaryInfo.h"
#include "llvm/IR/Constants.h"
#include "llvm/IR/GlobalAlias.h"
#include "llvm/IR/GlobalObject.h"
#include "llvm/IR/InstIterator.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/Jeandle/Attributes.h"
#include "llvm/IR/Jeandle/JeandleUtils.h"
#include "llvm/IR/Jeandle/Metadata.h"
#include "llvm/IR/Jeandle/VMCallback.h"
#include "llvm/IR/Metadata.h"
#include "llvm/IR/Module.h"
#include "llvm/IRReader/IRReader.h"
#include "llvm/Support/Debug.h"
#include "llvm/Support/ErrorHandling.h"
#include "llvm/Support/FileSystem.h"
#include "llvm/Support/Format.h"
#include "llvm/Support/SourceMgr.h"
#include "llvm/Support/Threading.h"
#include "llvm/Support/raw_ostream.h"
#include "llvm/Transforms/Utils/Cloning.h"
#include "llvm/Transforms/Utils/ValueMapper.h"

#include <limits>
#include <memory>
#include <string>
#include <utility>

#define DEBUG_TYPE "jeandle-inliner"

using namespace llvm;

using llvm::jeandle::getRootJavaMethodFunction;
using llvm::jeandle::isJeandleJavaMethod;
using llvm::jeandle::isRootJavaMethodFunction;

static bool isJeandleJavaAccessorMethod(const Function &F) {
  return F.hasFnAttribute(jeandle::Attribute::JavaAccessorMethod);
}

static bool isEligibleInlineCallee(const Function &F,
                                   bool InlineAccessorsOnly) {
  if (!isJeandleJavaMethod(F))
    return false;
  return !InlineAccessorsOnly || isJeandleJavaAccessorMethod(F);
}

static bool isMonomorphicTargetCall(const CallBase &CB) {
  return CB.getAttributes().hasFnAttr(jeandle::Attribute::MonomorphicTarget);
}

static PreservedAnalyses getInlineRoundPreservedAnalyses(bool Changed) {
  if (!Changed)
    return PreservedAnalyses::all();

  PreservedAnalyses PA;
  // InlineFunction mutates individual callers and those function analyses are
  // invalidated eagerly after each inline. Preserve the function-analysis proxy
  // here so the module pass manager does not discard unrelated function
  // analyses.
  PA.preserve<FunctionAnalysisManagerModuleProxy>();
  PA.preserveSet<AllAnalysesOn<Function>>();
  return PA;
}

static InlineRoundResult makeInlineRoundResult(bool Changed,
                                               bool ExposedNewCallSites) {
  InlineRoundResult Result;
  Result.PA = getInlineRoundPreservedAnalyses(Changed);
  Result.ExposedNewCallSites = ExposedNewCallSites;
  return Result;
}

static void setInlineScopeID(CallBase &CB, int InlineScopeID) {
  LLVMContext &Ctx = CB.getContext();
  auto *ScopeID = ConstantAsMetadata::get(ConstantInt::get(
      Type::getInt32Ty(Ctx), InlineScopeID, /*isSigned=*/true));
  Metadata *Ops[] = {ScopeID};
  CB.setMetadata(jeandle::Metadata::InlineScopeID, MDNode::get(Ctx, Ops));
}

static int getInlineScopeID(const CallBase &CB) {
  MDNode *MD = CB.getMetadata(jeandle::Metadata::InlineScopeID);
  if (!MD)
    return -1;

  if (MD->getNumOperands() != 1)
    report_fatal_error("JeandleInliner: invalid inline-scope-id metadata");

  auto *ScopeID = dyn_cast_or_null<ConstantAsMetadata>(MD->getOperand(0).get());
  if (!ScopeID)
    report_fatal_error("JeandleInliner: invalid inline-scope-id metadata");

  auto *CI = dyn_cast<ConstantInt>(ScopeID->getValue());
  if (!CI || !CI->getType()->isIntegerTy(32))
    report_fatal_error("JeandleInliner: invalid inline-scope-id metadata");

  return static_cast<int>(CI->getSExtValue());
}

[[noreturn]] static void reportInvalidStatepointID(const CallBase &CB,
                                                   const char *Reason) {
  std::string Message;
  raw_string_ostream OS(Message);

  OS << "JeandleInliner: " << Reason;
  if (const Function *Caller = CB.getCaller())
    OS << " in " << Caller->getName();
  OS << ": " << CB;

  OS.flush();
  report_fatal_error(StringRef(Message));
}

static bool getStatepointID(const CallBase &CB, uint64_t &StatepointID) {
  Attribute Attr =
      CB.getAttributes().getFnAttr(jeandle::Attribute::StatepointID);
  if (!Attr.isValid())
    return false;
  if (!Attr.isStringAttribute())
    reportInvalidStatepointID(CB, "invalid statepoint-id attribute");
  if (Attr.getValueAsString().getAsInteger(10, StatepointID))
    reportInvalidStatepointID(CB, "invalid statepoint-id attribute");
  return true;
}

static void setStatepointID(CallBase &CB, uint64_t StatepointID) {
  CB.removeFnAttr(jeandle::Attribute::StatepointID);
  CB.addFnAttr(Attribute::get(CB.getContext(), jeandle::Attribute::StatepointID,
                              std::to_string(StatepointID)));
}

// A statepoint-id points to JVM-side CallSiteInfo and must not be shared by
// an inlined copy and the original template call site. Only call sites that
// already carry statepoint-id need rewriting; helper/runtime calls without the
// attribute have no JVM state to clone. The VM owns global id allocation, so
// LLVM only asks for a fresh id and validates the returned value's shape.
static void ensureUniqueStatepointID(CallBase &CB,
                                     const jeandle::VMCallbacks &VC) {
  uint64_t StatepointID = 0;
  if (!getStatepointID(CB, StatepointID))
    return;
  assert(StatepointID <= uint64_t(std::numeric_limits<int64_t>::max()) &&
         "statepoint-id too large for GetNewStatepointID callback");

  int64_t NewStatepointID =
      VC.GetNewStatepointID(static_cast<int64_t>(StatepointID));
  if (NewStatepointID < 0)
    reportInvalidStatepointID(CB, "GetNewStatepointID returned a negative id");
  setStatepointID(CB, static_cast<uint64_t>(NewStatepointID));
}

static void logPassBoundary(const char *Phase, const Function &Root,
                            uint64_t ThreadID) {
  LLVM_DEBUG(dbgs() << "========== JeandleInliner " << left_justify(Phase, 5)
                    << " tid=" << ThreadID << " root=" << Root.getName()
                    << " ==========\n");
}

[[noreturn]] static void reportInvalidCallSiteBCI(const CallBase &CB,
                                                  const char *Reason) {
  std::string Message;
  raw_string_ostream OS(Message);

  OS << "JeandleInliner: " << Reason;
  if (const Function *Caller = CB.getCaller())
    OS << " in " << Caller->getName();
  if (const Function *Callee = CB.getCalledFunction())
    OS << " -> " << Callee->getName();
  OS << ": " << CB;

  OS.flush();
  report_fatal_error(StringRef(Message));
}

static int getCallSiteBCI(const CallBase &CB) {
  auto Deopt = CB.getOperandBundle(LLVMContext::OB_deopt);
  if (!Deopt)
    reportInvalidCallSiteBCI(CB, "missing deopt bundle for bci");

  // The frontend emits each frame as two adjacent i32 BCI values followed by
  // deopt value pairs. Previous inlining prepends parent deopt arguments, so
  // find the current call-site BCI by walking from the end and looking for the
  // last adjacent i32 pair. The pair must contain the same value.
  for (unsigned I = Deopt->Inputs.size(); I > 1; --I) {
    auto *BCI0 = dyn_cast<ConstantInt>(Deopt->Inputs[I - 2].get());
    auto *BCI1 = dyn_cast<ConstantInt>(Deopt->Inputs[I - 1].get());
    if (!BCI0 || !BCI1 || !BCI0->getType()->isIntegerTy(32) ||
        !BCI1->getType()->isIntegerTy(32))
      continue;
    if (BCI0->getSExtValue() != BCI1->getSExtValue())
      reportInvalidCallSiteBCI(CB, "mismatched adjacent i32 bci values");
    return static_cast<int>(BCI0->getSExtValue());
  }

  reportInvalidCallSiteBCI(CB, "missing adjacent i32 deopt bci pair");
}

[[noreturn]] static void reportInvalidJavaMethodAttribute(const Function &F,
                                                          const char *Reason) {
  std::string Message;
  raw_string_ostream OS(Message);

  OS << "JeandleInliner: " << Reason << " for " << F.getName();

  OS.flush();
  report_fatal_error(StringRef(Message));
}

static uintptr_t getJavaMethodPointer(const Function &F) {
  llvm::Attribute Attr = F.getFnAttribute(jeandle::Attribute::JavaMethod);
  if (!Attr.isStringAttribute())
    reportInvalidJavaMethodAttribute(F, "missing java method attribute value");

  StringRef Value = Attr.getValueAsString();
  if (Value.empty())
    reportInvalidJavaMethodAttribute(F, "empty java method attribute value");

  uint64_t Raw = 0;
  bool Failed = Value.getAsInteger(10, Raw);

  if (Failed || Raw > std::numeric_limits<uintptr_t>::max())
    reportInvalidJavaMethodAttribute(F, "invalid java method attribute value");

  return static_cast<uintptr_t>(Raw);
}

#ifndef NDEBUG
static void assertNoNonEntryAlloca(const Function &F) {
  const BasicBlock &Entry = F.getEntryBlock();
  for (const BasicBlock &BB : F) {
    if (&BB == &Entry)
      continue;
    for (const Instruction &I : BB)
      assert(!isa<AllocaInst>(&I) &&
             "JeandleInliner: non-entry alloca remains after inlining");
  }
}
#endif

// Returns the depth of the call site represented by this inline scope chain.
// Example: A calls B (depth 0), B calls C (depth 1), C calls D (depth 2).
[[maybe_unused]] static int getInlineScopeDepth(
    int InlineScopeID,
    const SmallVectorImpl<std::pair<Function *, int>> &InlineScopes) {
  int Depth = 0;
  while (InlineScopeID != -1) {
    assert(unsigned(InlineScopeID) < InlineScopes.size() &&
           "Invalid inline scope ID");
    Depth++;
    InlineScopeID = InlineScopes[InlineScopeID].second;
  }
  return Depth;
}

static Function *getInlineScopeCaller(
    Function *Root, int InlineScopeID,
    const SmallVectorImpl<std::pair<Function *, int>> &InlineScopes) {
  if (InlineScopeID == -1)
    return Root;
  assert(unsigned(InlineScopeID) < InlineScopes.size() &&
         "Invalid inline scope ID");
  return InlineScopes[InlineScopeID].first;
}

static void logInlineEvent(
    const char *Event, Function *ScopeCaller, int BCI, Function *Callee,
    int InlineScopeID, uint64_t ThreadID,
    const SmallVectorImpl<std::pair<Function *, int>> &InlineScopes) {
  LLVM_DEBUG(dbgs() << "[tid=" << ThreadID << ", depth="
                    << getInlineScopeDepth(InlineScopeID, InlineScopes) << "] "
                    << left_justify(Event, 11) << " for "
                    << ScopeCaller->getName() << " @" << BCI << " -> "
                    << Callee->getName() << "\n");
}

static void recordInlineResult(const jeandle::VMCallbacks &VC,
                               int InlineScopeID, int BCI,
                               uintptr_t CalleeMethod,
                               jeandle::JeandleInlineReason Reason) {
  bool Recorded = VC.RecordInlineResult(InlineScopeID, BCI, CalleeMethod,
                                        static_cast<int>(Reason));
  assert(Recorded && "RecordInlineResult must succeed");
  (void)Recorded;
}

InlineRoundResult JeandleInliner::runInlineRound(
    Module &M, ModuleAnalysisManager &MAM,
    SmallVectorImpl<JeandleInlineScope> &InlineScopes) {
  if (!M.getNamedMetadata(jeandle::Metadata::JavaMethodCompilation)) {
    return makeInlineRoundResult(/*Changed=*/false,
                                 /*ExposedNewCallSites=*/false);
  }

  const jeandle::VMCallbacks *VC = jeandle::getVMCallbacks();
  if (!VC) {
    LLVM_DEBUG(dbgs() << "JeandleInliner: no VMCallbacks, skipping\n");
    return makeInlineRoundResult(/*Changed=*/false,
                                 /*ExposedNewCallSites=*/false);
  }
  if (!VC->IsOkToInline) {
    LLVM_DEBUG(
        dbgs() << "JeandleInliner: no IsOkToInline callback, skipping\n");
    return makeInlineRoundResult(/*Changed=*/false,
                                 /*ExposedNewCallSites=*/false);
  }
  if (!VC->GetInlineCalleeIR) {
    LLVM_DEBUG(
        dbgs() << "JeandleInliner: no GetInlineCalleeIR callback, skipping\n");
    return makeInlineRoundResult(/*Changed=*/false,
                                 /*ExposedNewCallSites=*/false);
  }
  if (!VC->GetNewStatepointID) {
    LLVM_DEBUG(
        dbgs() << "JeandleInliner: no GetNewStatepointID callback, skipping\n");
    return makeInlineRoundResult(/*Changed=*/false,
                                 /*ExposedNewCallSites=*/false);
  }
  if (!VC->RecordInlineResult) {
    LLVM_DEBUG(
        dbgs() << "JeandleInliner: no RecordInlineResult callback, skipping\n");
    return makeInlineRoundResult(/*Changed=*/false,
                                 /*ExposedNewCallSites=*/false);
  }

  FunctionAnalysisManager &FAM =
      MAM.getResult<FunctionAnalysisManagerModuleProxy>(M).getManager();
  auto &PSI = MAM.getResult<ProfileSummaryAnalysis>(M);

  auto GetAAR = [&](Function &F) -> AAResults & {
    return FAM.getResult<AAManager>(F);
  };
  auto GetAssumptionCache = [&](Function &F) -> AssumptionCache & {
    return FAM.getResult<AssumptionAnalysis>(F);
  };

  SmallVector<std::pair<CallBase *, int>, 16> Worklist;
  SmallPtrSet<const CallBase *, 32> KnownCallSites;
  Function *RootFunction = getRootJavaMethodFunction(M);
  if (!RootFunction)
    return makeInlineRoundResult(/*Changed=*/false,
                                 /*ExposedNewCallSites=*/false);

  for (Instruction &I : instructions(RootFunction)) {
    auto *CB = dyn_cast<CallBase>(&I);
    if (!CB)
      continue;
    KnownCallSites.insert(CB);
    Function *Callee = CB->getCalledFunction();
    if (!Callee || !isEligibleInlineCallee(*Callee, InlineAccessorsOnly))
      continue;
    if (!isMonomorphicTargetCall(*CB))
      continue;
    if (CB->isNoInline())
      continue;
    Worklist.push_back({CB, getInlineScopeID(*CB)});
  }

  uint64_t ThreadID = llvm::get_threadid();
  logPassBoundary("begin", *RootFunction, ThreadID);

  bool Changed = false;
  bool ExposedNewCallSites = false;

  for (unsigned I = 0; I < Worklist.size(); ++I) {
    CallBase *CB = Worklist[I].first;
    int InlineScopeID = Worklist[I].second;

    if (!CB || !CB->getCaller())
      continue;

    Function *Caller = CB->getCaller();
    Function *Callee = CB->getCalledFunction();

    if (!Callee || !isEligibleInlineCallee(*Callee, InlineAccessorsOnly))
      continue;
    if (!isMonomorphicTargetCall(*CB))
      continue;
    if (CB->isNoInline())
      continue;

    int BCI = getCallSiteBCI(*CB);
    Function *ScopeCaller =
        getInlineScopeCaller(RootFunction, InlineScopeID, InlineScopes);

    uintptr_t CalleeMethod = getJavaMethodPointer(*Callee);

    // TODO: Support inlining the root method as a callee once root/caller IR
    // and callee IR use the same unwind model. The root emits real unwind
    // operations, while an inlined callee forwards unwind edges to the
    // caller's landingpad. Mark root callees noinline so later LLVM inline
    // passes cannot inline them either.
    if (CalleeMethod == getJavaMethodPointer(*RootFunction)) {
      CB->setIsNoInline();
      recordInlineResult(*VC, InlineScopeID, BCI, CalleeMethod,
                         jeandle::JeandleInlineReason::RootCalleeUnsupported);
      continue;
    }

    bool IsOkToInline = VC->IsOkToInline(InlineScopeID, BCI, CalleeMethod);

    if (!IsOkToInline) {
      logInlineEvent("no-inline", ScopeCaller, BCI, Callee, InlineScopeID,
                     ThreadID, InlineScopes);
      continue;
    }

    if (Callee->isDeclaration()) {
      logInlineEvent("request-ir", ScopeCaller, BCI, Callee, InlineScopeID,
                     ThreadID, InlineScopes);
      bool GotCalleeIR = VC->GetInlineCalleeIR(CalleeMethod);
      if (!GotCalleeIR) {
        logInlineEvent("missing-ir", ScopeCaller, BCI, Callee, InlineScopeID,
                       ThreadID, InlineScopes);
        recordInlineResult(
            *VC, InlineScopeID, BCI, CalleeMethod,
            jeandle::JeandleInlineReason::GetInlineCalleeIRFailed);
        continue;
      }
      Changed = true;
      if (Callee->isDeclaration()) {
        logInlineEvent("missing-def", ScopeCaller, BCI, Callee, InlineScopeID,
                       ThreadID, InlineScopes);
        recordInlineResult(
            *VC, InlineScopeID, BCI, CalleeMethod,
            jeandle::JeandleInlineReason::MissingInlineCalleeDefinition);
        continue;
      }
    }

    auto inlineResult = isInlineViable(*Callee);
    if (!inlineResult.isSuccess()) {
      LLVM_DEBUG(dbgs() << "[tid=" << ThreadID << ", depth="
                        << getInlineScopeDepth(InlineScopeID, InlineScopes)
                        << "] " << left_justify("not-viable", 11) << " for "
                        << ScopeCaller->getName() << " @" << BCI << " -> "
                        << Callee->getName() << ": "
                        << inlineResult.getFailureReason() << "\n");
      recordInlineResult(*VC, InlineScopeID, BCI, CalleeMethod,
                         jeandle::JeandleInlineReason::NotInlineViable);
      continue;
    }

    InlineFunctionInfo IFI(GetAssumptionCache, &PSI,
                           &FAM.getResult<BlockFrequencyAnalysis>(*Caller),
                           &FAM.getResult<BlockFrequencyAnalysis>(*Callee));

    InlineResult IR = InlineFunction(*CB, IFI, /*MergeAttributes=*/true,
                                     &GetAAR(*Caller), /*InsertLifetime=*/true);
    if (!IR.isSuccess()) {
      LLVM_DEBUG(dbgs() << "[tid=" << ThreadID << ", depth="
                        << getInlineScopeDepth(InlineScopeID, InlineScopes)
                        << "] " << left_justify("failed-ir", 11) << " for "
                        << ScopeCaller->getName() << " @" << BCI << " -> "
                        << Callee->getName() << ": " << IR.getFailureReason()
                        << "\n");
      recordInlineResult(*VC, InlineScopeID, BCI, CalleeMethod,
                         jeandle::JeandleInlineReason::LLVMInlineFailed);
      continue;
    } else {
#ifndef NDEBUG
      // The JVM frontend guarantees that callee allocas are static allocas, so
      // InlineFunction should hoist them into the caller entry block. Recheck
      // that invariant in debug builds.
      assertNoNonEntryAlloca(*Caller);
#endif
      recordInlineResult(*VC, InlineScopeID, BCI, CalleeMethod,
                         jeandle::JeandleInlineReason::InlineSuccess);
    }

    Changed = true;

    logInlineEvent("inlined", ScopeCaller, BCI, Callee, InlineScopeID, ThreadID,
                   InlineScopes);

    FAM.invalidate(*Caller, PreservedAnalyses::none());

    // Record this inlining in the inline scope chain. Each entry stores
    // (the callee that was inlined, the parent scope ID). The chain identifies
    // the scope passed to VM callbacks and supports log depth computation.
    int NewScopeID = InlineScopes.size();
    InlineScopes.push_back({Callee, InlineScopeID});

    // After inlining, the callee's body is merged into the caller, which may
    // expose new call sites that were previously inside the callee. Do not rely
    // on IFI.InlinedCallSites here: LLVM only fills it after checking
    // ClonedCodeInfo::ContainsCalls, which tracks normal CallInsts and can miss
    // invoke-only inlinees. JeandleInlineDriver uses exposed call sites as an
    // iteration signal, so compute new CallBase objects by comparing the caller
    // after InlineFunction against the call site set from the previous scan.
    //
    // Future devirtualization refinement should run from JeandleInlineDriver
    // after an inline round exposes new call sites. This round's worklist is
    // local to the round and is not carried across that step. The driver owns
    // InlineScopes; devirtualization only needs to preserve inline-scope-id
    // metadata on surviving or generated call sites.
    //
    // New call sites that survive this immediate worklist keep their scope via
    // NewScopeID. If future devirtualization rewrites a call into guarded
    // direct calls, it must propagate the same inline scope to the generated
    // calls.
    SmallVector<CallBase *, 8> NewCallSites;
    SmallPtrSet<const CallBase *, 32> CurrentCallSites;
    for (Instruction &I : instructions(Caller)) {
      auto *NewCB = dyn_cast<CallBase>(&I);
      if (!NewCB)
        continue;
      CurrentCallSites.insert(NewCB);
      if (KnownCallSites.contains(NewCB))
        continue;
      NewCallSites.push_back(NewCB);
    }
    KnownCallSites = std::move(CurrentCallSites);

    for (CallBase *NewCB : NewCallSites) {
      // Statepoint ids in callee IR belong to the original template call sites.
      // Every inlined copy must get a fresh JVM-side id so updating its
      // CallSiteInfo cannot affect the template or an uninlined call site.
      ensureUniqueStatepointID(*NewCB, *VC);
      setInlineScopeID(*NewCB, NewScopeID);
      ExposedNewCallSites = true;

      Function *NewCallee = NewCB->getCalledFunction();
      // TODO: Support inlining the root method as a callee once root/caller IR
      // and callee IR use the same unwind model. The root emits real unwind
      // operations, while an inlined callee forwards unwind edges to the
      // caller's landingpad. Mark root callees noinline so later LLVM inline
      // passes cannot inline them either.
      if (NewCallee && isJeandleJavaMethod(*NewCallee) &&
          getJavaMethodPointer(*NewCallee) ==
              getJavaMethodPointer(*RootFunction)) {
        NewCB->setIsNoInline();
        continue;
      }
      if (!NewCallee ||
          !isEligibleInlineCallee(*NewCallee, InlineAccessorsOnly) ||
          !isMonomorphicTargetCall(*NewCB) || NewCB->isNoInline())
        continue;
      Worklist.push_back({NewCB, NewScopeID});
    }
  }

  logPassBoundary("end", *RootFunction, ThreadID);
  return makeInlineRoundResult(Changed, ExposedNewCallSites);
}

PreservedAnalyses JeandleInliner::run(Module &M, ModuleAnalysisManager &MAM) {
  SmallVector<JeandleInlineScope, 16> InlineScopes;
  return runInlineRound(M, MAM, InlineScopes).PA;
}

/* ------------- Inline callee replay support begin ------------- */

struct InlineCalleeIRReplayState {
  std::unique_ptr<Module> ReplayModule;
  DenseMap<uintptr_t, Function *> Callees;
  ValueToValueMapTy VMap;
  Module *DestModule = nullptr;
  std::string ReplayPath;
};

static thread_local InlineCalleeIRReplayState InlineCalleeReplayState;

void llvm::jeandle::detail::clearInlineCalleeReplayState() {
  InlineCalleeReplayState.VMap.clear();
  InlineCalleeReplayState.Callees.clear();
  InlineCalleeReplayState.ReplayModule.reset();
  InlineCalleeReplayState.DestModule = nullptr;
  InlineCalleeReplayState.ReplayPath.clear();
}

static std::string formatSMDiagnostic(const SMDiagnostic &Diag) {
  std::string Message;
  raw_string_ostream OS(Message);
  Diag.print("JeandleInliner", OS);
  return Message;
}

static void loadInlineCalleeReplayModule(Module &DestM, StringRef ReplayPath) {
  if (InlineCalleeReplayState.ReplayModule &&
      InlineCalleeReplayState.DestModule == &DestM &&
      InlineCalleeReplayState.ReplayPath == ReplayPath)
    return;

  jeandle::detail::clearInlineCalleeReplayState();

  SMDiagnostic Diag;
  std::unique_ptr<Module> ReplayM =
      parseIRFile(ReplayPath, Diag, DestM.getContext());
  if (!ReplayM) {
    std::string DiagMessage = formatSMDiagnostic(Diag);
    report_fatal_error("JeandleInliner: cannot parse inline callee replay "
                       "module '" +
                       Twine(ReplayPath) + "': " + DiagMessage);
  }

#ifndef NDEBUG
  if (!ReplayM->ifunc_empty())
    report_fatal_error(
        "JeandleInliner: inline callee replay module contains ifuncs");
#endif

  for (Function &F : *ReplayM) {
    if (!isJeandleJavaMethod(F))
      continue;

    if (F.isDeclaration())
      continue;

    uintptr_t Method = getJavaMethodPointer(F);

    auto [It, Inserted] =
        InlineCalleeReplayState.Callees.try_emplace(Method, &F);
    if (!Inserted && It->second->getName() != F.getName())
      report_fatal_error("JeandleInliner: duplicate java method pointer " +
                         Twine(static_cast<unsigned long long>(Method)) +
                         " for inline callee replay functions '" +
                         It->second->getName() + "' and '" + F.getName() + "'");
  }

  InlineCalleeReplayState.ReplayModule = std::move(ReplayM);
  InlineCalleeReplayState.DestModule = &DestM;
  InlineCalleeReplayState.ReplayPath = ReplayPath.str();
}

struct InlineCalleeReplayCloneWorklist {
  SmallVector<std::pair<const GlobalVariable *, GlobalVariable *>, 8>
      GlobalVariables;
  SmallVector<std::pair<const GlobalAlias *, GlobalAlias *>, 4> Aliases;
};

static void verifyReplayGlobalObjectHasNoComdat(const GlobalObject &Src) {
  if (!Src.getComdat())
    return;

  report_fatal_error("JeandleInliner: inline callee replay global object '" +
                     Twine(Src.getName()) + "' unexpectedly has comdat");
}

[[noreturn]] static void
reportInvalidReplayGlobalReference(const Function &SrcF, const GlobalValue &GV,
                                   StringRef Reason) {
  std::string Message;
  raw_string_ostream OS(Message);

  OS << "JeandleInliner: inline callee replay function '" << SrcF.getName()
     << "' references global value ";
  if (GV.hasName())
    OS << "'" << GV.getName() << "'";
  else
    OS << "<unnamed>";
  OS << ": " << Reason;

  OS.flush();
  report_fatal_error(StringRef(Message));
}

static void verifyReplayValueMapped(const Value *V, const Function &SrcF,
                                    const ValueToValueMapTy &VMap,
                                    SmallPtrSetImpl<const Value *> &Visited) {
  V = V->stripPointerCasts();
  if (const auto *GV = dyn_cast<GlobalValue>(V)) {
    auto It = VMap.find(GV);
    if (It == VMap.end() || !It->second)
      reportInvalidReplayGlobalReference(
          SrcF, *GV, "missing mapping in the destination module");
    if (It->second->getType() != GV->getType())
      reportInvalidReplayGlobalReference(
          SrcF, *GV, "mismatched type in the destination module");
    return;
  }

  const auto *C = dyn_cast<Constant>(V);
  if (!C || !Visited.insert(C).second)
    return;

  for (const Use &Op : C->operands())
    verifyReplayValueMapped(Op.get(), SrcF, VMap, Visited);
}

static void
populateReplayValueDependencies(Module &DestM, const Value *V,
                                ValueToValueMapTy &VMap,
                                InlineCalleeReplayCloneWorklist &CloneWorklist,
                                SmallPtrSetImpl<const Value *> &Visited);

static void mapReplayGlobalValue(Module &DestM, const GlobalValue &SrcGV,
                                 ValueToValueMapTy &VMap,
                                 InlineCalleeReplayCloneWorklist &CloneWorklist,
                                 SmallPtrSetImpl<const Value *> &Visited) {
  if (VMap.count(&SrcGV))
    return;

  if (const auto *SrcGO = dyn_cast<GlobalObject>(&SrcGV))
    verifyReplayGlobalObjectHasNoComdat(*SrcGO);

  // ReplayM is a copy of an earlier complete DestM. For GlobalVariable,
  // Function, and GlobalAlias values, a same-named value in DestM is therefore
  // the canonical value to use. Clone only values that are actually referenced
  // by the current callee and are absent from DestM.
  if (GlobalValue *DstGV = DestM.getNamedValue(SrcGV.getName())) {
    VMap[&SrcGV] = DstGV;
    return;
  }

  if (const auto *SrcG = dyn_cast<GlobalVariable>(&SrcGV)) {
    auto *NewGV = new GlobalVariable(
        DestM, SrcG->getValueType(), SrcG->isConstant(), SrcG->getLinkage(),
        /*Initializer=*/nullptr, SrcG->getName(),
        /*InsertBefore=*/nullptr, SrcG->getThreadLocalMode(),
        SrcG->getType()->getAddressSpace(), SrcG->isExternallyInitialized());
    NewGV->copyAttributesFrom(SrcG);
    VMap[SrcG] = NewGV;
    CloneWorklist.GlobalVariables.push_back({SrcG, NewGV});
    if (SrcG->hasInitializer())
      populateReplayValueDependencies(DestM, SrcG->getInitializer(), VMap,
                                      CloneWorklist, Visited);
    return;
  }

  if (const auto *SrcF = dyn_cast<Function>(&SrcGV)) {
    if (!SrcF->isDeclaration())
      report_fatal_error("JeandleInliner: inline callee replay function '" +
                         Twine(SrcF->getName()) +
                         "' is missing in the destination module but has a "
                         "definition");

    Function *NewF = Function::Create(
        cast<FunctionType>(SrcF->getValueType()), GlobalValue::ExternalLinkage,
        SrcF->getAddressSpace(), SrcF->getName(), &DestM);
    NewF->copyAttributesFrom(SrcF);
    NewF->setPersonalityFn(nullptr);
    VMap[SrcF] = NewF;
    return;
  }

  if (const auto *SrcA = dyn_cast<GlobalAlias>(&SrcGV)) {
    GlobalAlias *NewA =
        GlobalAlias::create(SrcA->getValueType(), SrcA->getAddressSpace(),
                            SrcA->getLinkage(), SrcA->getName(), &DestM);
    NewA->copyAttributesFrom(SrcA);
    VMap[SrcA] = NewA;
    CloneWorklist.Aliases.push_back({SrcA, NewA});
    if (const Constant *Aliasee = SrcA->getAliasee())
      populateReplayValueDependencies(DestM, Aliasee, VMap, CloneWorklist,
                                      Visited);
    return;
  }

  report_fatal_error("JeandleInliner: unsupported inline callee replay global "
                     "value kind for '" +
                     Twine(SrcGV.getName()) + "'");
}

static void
populateReplayValueDependencies(Module &DestM, const Value *V,
                                ValueToValueMapTy &VMap,
                                InlineCalleeReplayCloneWorklist &CloneWorklist,
                                SmallPtrSetImpl<const Value *> &Visited) {
  V = V->stripPointerCasts();
  if (const auto *GV = dyn_cast<GlobalValue>(V)) {
    mapReplayGlobalValue(DestM, *GV, VMap, CloneWorklist, Visited);
    return;
  }

  const auto *C = dyn_cast<Constant>(V);
  if (!C || !Visited.insert(C).second)
    return;

  for (const Use &Op : C->operands())
    populateReplayValueDependencies(DestM, Op.get(), VMap, CloneWorklist,
                                    Visited);
}

static void cloneReplayGlobalValueDefinitions(
    ValueToValueMapTy &VMap, InlineCalleeReplayCloneWorklist &CloneWorklist) {
  for (auto [SrcG, DstG] : CloneWorklist.GlobalVariables) {
    if (SrcG->hasInitializer())
      DstG->setInitializer(
          cast<Constant>(MapValue(SrcG->getInitializer(), VMap)));
  }

  for (auto [SrcA, DstA] : CloneWorklist.Aliases) {
    if (const Constant *Aliasee = SrcA->getAliasee())
      DstA->setAliasee(cast<Constant>(MapValue(Aliasee, VMap)));
  }
}

static void mapReplayPersonalityFunction(Module &DestM, const Function &SrcF,
                                         ValueToValueMapTy &VMap) {
  if (!SrcF.hasPersonalityFn())
    report_fatal_error("JeandleInliner: inline callee replay function '" +
                       Twine(SrcF.getName()) +
                       "' is missing jeandle.personality");

  Constant *SrcPersonality = SrcF.getPersonalityFn();
  auto *SrcPersonalityGV =
      dyn_cast<GlobalValue>(SrcPersonality->stripPointerCasts());
  if (!SrcPersonalityGV || SrcPersonalityGV->getName() != "jeandle.personality")
    report_fatal_error("JeandleInliner: unexpected inline callee replay "
                       "personality function for '" +
                       Twine(SrcF.getName()) + "'");

  GlobalVariable *DstPersonality =
      DestM.getGlobalVariable("jeandle.personality");
  if (!DstPersonality)
    report_fatal_error("JeandleInliner: missing destination "
                       "jeandle.personality global");

  VMap[SrcPersonality] = DstPersonality;
}

static void populateInlineCalleeReplayVMap(Module &DestM, const Function &SrcF,
                                           Function &DstF,
                                           ValueToValueMapTy &VMap) {
  InlineCalleeReplayCloneWorklist CloneWorklist;
  VMap[&SrcF] = &DstF;
  verifyReplayGlobalObjectHasNoComdat(SrcF);

  if (SrcF.arg_size() != DstF.arg_size())
    report_fatal_error("JeandleInliner: inline callee replay function '" +
                       Twine(SrcF.getName()) +
                       "' has an argument count mismatch");

  for (auto [SrcArg, DstArg] : zip(SrcF.args(), DstF.args()))
    VMap[&SrcArg] = &DstArg;

  mapReplayPersonalityFunction(DestM, SrcF, VMap);

  if (SrcF.hasPrefixData())
    report_fatal_error("JeandleInliner: inline callee replay function '" +
                       Twine(SrcF.getName()) +
                       "' unexpectedly has prefix data");
  if (SrcF.hasPrologueData())
    report_fatal_error("JeandleInliner: inline callee replay function '" +
                       Twine(SrcF.getName()) +
                       "' unexpectedly has prologue data");

  SmallPtrSet<const Value *, 16> DependencyVisited;
  for (const Instruction &I : instructions(SrcF)) {
    for (const Use &Op : I.operands())
      populateReplayValueDependencies(DestM, Op.get(), VMap, CloneWorklist,
                                      DependencyVisited);
  }

  cloneReplayGlobalValueDefinitions(VMap, CloneWorklist);

  SmallPtrSet<const Value *, 16> Visited;
  for (const Instruction &I : instructions(SrcF)) {
    for (const Use &Op : I.operands())
      verifyReplayValueMapped(Op.get(), SrcF, VMap, Visited);
  }
}

static void cloneInlineCalleeForReplay(Module &DestM, const Function &SrcF) {
  Function *DstF = DestM.getFunction(SrcF.getName());
  if (!DstF)
    report_fatal_error("JeandleInliner: inline callee replay function '" +
                       Twine(SrcF.getName()) +
                       "' has no declaration in the destination module");

  if (!DstF->isDeclaration())
    return;

  if (DstF->getFunctionType() != SrcF.getFunctionType())
    report_fatal_error("JeandleInliner: inline callee replay function '" +
                       Twine(SrcF.getName()) +
                       "' has a mismatched function type");

  ValueToValueMapTy &VMap = InlineCalleeReplayState.VMap;
  populateInlineCalleeReplayVMap(DestM, SrcF, *DstF, VMap);

  SmallVector<ReturnInst *, 8> Returns;
  CloneFunctionInto(DstF, &SrcF, VMap, CloneFunctionChangeType::DifferentModule,
                    Returns);
  DstF->setLinkage(GlobalValue::AvailableExternallyLinkage);
}

void llvm::jeandle::detail::materializeInlineCalleeIRForReplay(
    Module &M, StringRef InlineCalleeIRPath, uintptr_t CalleeMethod) {
  if (!sys::fs::exists(InlineCalleeIRPath))
    report_fatal_error("JeandleInliner: GetInlineCalleeIR replay returned "
                       "true, but inline callee replay module '" +
                       Twine(InlineCalleeIRPath) + "' does not exist");

  loadInlineCalleeReplayModule(M, InlineCalleeIRPath);

  // This hook is reached only when GetInlineCalleeIR replay returns true, so
  // the replay module must contain the requested callee IR definition.
  auto It = InlineCalleeReplayState.Callees.find(CalleeMethod);
  if (It == InlineCalleeReplayState.Callees.end())
    report_fatal_error("JeandleInliner: missing callee method " +
                       Twine(static_cast<unsigned long long>(CalleeMethod)) +
                       " in inline callee replay module '" +
                       InlineCalleeIRPath + "'");

  cloneInlineCalleeForReplay(M, *It->second);
}

/* -------------- Inline callee replay support end -------------- */
