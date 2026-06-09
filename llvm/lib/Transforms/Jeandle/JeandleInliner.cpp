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
// This file implements the JeandleInlineDriver and JeandleInliner passes for
// Jeandle JVM JIT. Unlike the standard InlinerPass which operates on the
// LazyCallGraph/SCC, the current inline step walks call sites in the module
// directly.
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
// original module and for call sites exposed after inlining. The driver is the
// extension point for future CHA/PGO refinement between inline rounds so newly
// exposed call sites can be specialized before they are reconsidered.
//
//===----------------------------------------------------------------------===//

#include "llvm/Transforms/Jeandle/JeandleInliner.h"

#include "llvm/ADT/STLExtras.h"
#include "llvm/ADT/SmallVector.h"
#include "llvm/Analysis/AliasAnalysis.h"
#include "llvm/Analysis/AssumptionCache.h"
#include "llvm/Analysis/InlineCost.h"
#include "llvm/Analysis/OptimizationRemarkEmitter.h"
#include "llvm/Analysis/ProfileSummaryInfo.h"
#include "llvm/IR/Constants.h"
#include "llvm/IR/InstIterator.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/Jeandle/Attributes.h"
#include "llvm/IR/Jeandle/Metadata.h"
#include "llvm/IR/Jeandle/VMCallback.h"
#include "llvm/IR/Metadata.h"
#include "llvm/IR/Module.h"
#include "llvm/Support/Debug.h"
#include "llvm/Support/ErrorHandling.h"
#include "llvm/Support/Format.h"
#include "llvm/Support/Threading.h"
#include "llvm/Support/raw_ostream.h"
#include "llvm/Transforms/Utils/Cloning.h"

#include <string>

#define DEBUG_TYPE "jeandle-inliner"

using namespace llvm;

static bool isJeandleJavaMethod(const Function &F) {
  return F.hasFnAttribute(jeandle::Attribute::JavaMethod);
}

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

static bool isRootJavaMethodFunction(const Function &F) {
  return isJeandleJavaMethod(F) && !F.isDeclaration() &&
         !F.hasAvailableExternallyLinkage();
}

static Function *getRootJavaMethodFunction(Module &M) {
  Function *RootFunction = nullptr;
  for (Function &F : M) {
    if (!isRootJavaMethodFunction(F))
      continue;
    if (!RootFunction) {
      RootFunction = &F;
    } else {
      std::string Message;
      raw_string_ostream OS(Message);
      OS << "JeandleInliner: expected at most one root Java method function, "
         << "found '" << RootFunction->getName() << "' and '" << F.getName()
         << "'";
      OS.flush();
      report_fatal_error(StringRef(Message));
    }
  }
  return RootFunction;
}

struct InlineRoundResult {
  PreservedAnalyses PA;
  bool Changed = false;
  bool ExposedNewCallSites = false;
};

struct MonomorphicTargetDiscoveryResult {
  bool Changed = false;
  bool AddedMonomorphicTargets = false;
};

static PreservedAnalyses getInlineRoundPreservedAnalyses(bool Changed) {
  if (!Changed)
    return PreservedAnalyses::all();

  PreservedAnalyses PA;
  // InlineFunction mutates individual callers and those function analyses are
  // invalidated eagerly after each inline. Preserve the function-analysis proxy
  // here so the module pass manager does not discard unrelated function
  // analyses.
  PA.preserveSet<AllAnalysesOn<Function>>();
  return PA;
}

static InlineRoundResult makeInlineRoundResult(bool Changed,
                                               bool ExposedNewCallSites) {
  InlineRoundResult Result;
  Result.PA = getInlineRoundPreservedAnalyses(Changed);
  Result.Changed = Changed;
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

static bool eraseInlineScopeIDs(Function &RootFunction) {
  bool Changed = false;
  for (Instruction &I : instructions(RootFunction)) {
    auto *CB = dyn_cast<CallBase>(&I);
    if (!CB || !CB->getMetadata(jeandle::Metadata::InlineScopeID))
      continue;
    CB->setMetadata(jeandle::Metadata::InlineScopeID, nullptr);
    Changed = true;
  }
  return Changed;
}

static bool eraseAvailableExternallyJavaMethods(Module &M,
                                                Function *RootFunction) {
  SmallVector<Function *, 16> Candidates;
  bool Changed = false;

  for (Function &F : M) {
    if (&F == RootFunction || !isJeandleJavaMethod(F) ||
        !F.hasAvailableExternallyLinkage())
      continue;
    Candidates.push_back(&F);
  }

  for (Function *F : Candidates) {
    if (F->isDeclaration())
      continue;
    F->deleteBody();
    Changed = true;
  }

  for (Function *F : Candidates) {
    if (!F->use_empty())
      continue;
    F->eraseFromParent();
    Changed = true;
  }

  return Changed;
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

// Returns the depth of the call site represented by this inline scope chain.
// Example: A calls B (depth 0), B calls C (depth 1), C calls D (depth 2).
static int getInlineScopeDepth(
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

static InlineRoundResult
runInlineRound(Module &M, ModuleAnalysisManager &MAM, bool InlineAccessorsOnly,
               SmallVectorImpl<std::pair<Function *, int>> &InlineScopes) {
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
  if (!VC->RecordInlineSuccess) {
    LLVM_DEBUG(
        dbgs()
        << "JeandleInliner: no RecordInlineSuccess callback, skipping\n");
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
  Function *RootFunction = getRootJavaMethodFunction(M);
  if (!RootFunction)
    return makeInlineRoundResult(/*Changed=*/false,
                                 /*ExposedNewCallSites=*/false);

  for (Instruction &I : instructions(RootFunction)) {
    auto *CB = dyn_cast<CallBase>(&I);
    if (!CB)
      continue;
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

    // Root/caller IR and callee IR handle unwind differently: the root emits
    // real unwind operations, while an inlined callee forwards unwind edges to
    // the caller's landingpad. Never inline the root as a callee, and mark the
    // call site so later LLVM inline passes cannot inline it either. Non-root
    // recursion is left to the VM policy callback below.
    if (Callee == RootFunction) {
      logInlineEvent("root-callee", ScopeCaller, BCI, Callee, InlineScopeID,
                     ThreadID, InlineScopes);
      CB->setIsNoInline();
      Changed = true;
      continue;
    }

    bool IsOkToInline = VC->IsOkToInline(InlineScopeID, BCI,
                                         (uintptr_t)Callee->getName().data());

    if (!IsOkToInline) {
      logInlineEvent("no-inline", ScopeCaller, BCI, Callee, InlineScopeID,
                     ThreadID, InlineScopes);
      continue;
    }

    if (Callee->isDeclaration()) {
      logInlineEvent("request-ir", ScopeCaller, BCI, Callee, InlineScopeID,
                     ThreadID, InlineScopes);
      bool GotCalleeIR =
          VC->GetInlineCalleeIR((uintptr_t)Callee->getName().data());
      if (!GotCalleeIR) {
        logInlineEvent("missing-ir", ScopeCaller, BCI, Callee, InlineScopeID,
                       ThreadID, InlineScopes);
        continue;
      }
      if (Callee->isDeclaration()) {
        logInlineEvent("missing-def", ScopeCaller, BCI, Callee, InlineScopeID,
                       ThreadID, InlineScopes);
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
      continue;
    } else {
      bool Recorded = VC->RecordInlineSuccess(
          InlineScopeID, BCI, (uintptr_t)Callee->getName().data());
      if (!Recorded) {
        logInlineEvent("record-fail", ScopeCaller, BCI, Callee, InlineScopeID,
                       ThreadID, InlineScopes);
      }
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
    // expose new call sites that were previously inside the callee. These are
    // collected in IFI.InlinedCallSites (in top-down instruction order). Today
    // we enqueue only call sites that are already marked MonomorphicTarget.
    //
    // Future CHA/PGO refinement should run from JeandleInlineDriver after an
    // inline round exposes new call sites. Those passes may rewrite the root IR
    // and replace these CallBase objects, so any cross-pass worklist must be
    // rebuilt from IR while preserving inline scope information.
    //
    // New call sites that survive this immediate worklist keep their scope via
    // NewScopeID. If future CHA/PGO rewrites a call into guarded direct calls,
    // it must propagate the same inline scope to the generated calls.
    //
    // We use reverse order to match the convention of the standard InlinerPass.
    // Since the worklist is processed front-to-back, reverse causes call sites
    // later in the function to be appended first and thus processed first.
    // This is a minor detail for our pass; the standard InlinerPass uses this
    // convention because it processes calls grouped by caller, and the exact
    // ordering within a group has subtle effects on inline cost analysis.
    for (CallBase *NewCB : reverse(IFI.InlinedCallSites)) {
      setInlineScopeID(*NewCB, NewScopeID);
      ExposedNewCallSites = true;

      Function *NewCallee = NewCB->getCalledFunction();
      if (!NewCallee ||
          !isEligibleInlineCallee(*NewCallee, InlineAccessorsOnly) ||
          !isMonomorphicTargetCall(*NewCB) || NewCB->isNoInline())
        continue;
      Worklist.push_back({NewCB, NewScopeID});
    }
  }

  if (!Changed) {
    logPassBoundary("end", *RootFunction, ThreadID);
    return makeInlineRoundResult(/*Changed=*/false,
                                 /*ExposedNewCallSites=*/false);
  }

  logPassBoundary("end", *RootFunction, ThreadID);
  return makeInlineRoundResult(/*Changed=*/true, ExposedNewCallSites);
}

PreservedAnalyses JeandleInliner::run(Module &M, ModuleAnalysisManager &MAM) {
  SmallVector<std::pair<Function *, int>, 16> InlineScopes;
  return runInlineRound(M, MAM, InlineAccessorsOnly, InlineScopes).PA;
}

static MonomorphicTargetDiscoveryResult
runCHARefinement(Module &, ModuleAnalysisManager &) {
  // TODO: Run the CHA refinement pass here. It should inspect call sites
  // exposed by the previous inline round, mark newly monomorphic direct calls
  // with llvm::jeandle::Attribute::MonomorphicTarget, and/or rewrite a virtual
  // call into guarded direct calls.
  //
  // Any call site cloned or replaced by CHA must inherit:
  //   - the inline-scope-id metadata from the original call site, so the next
  //     inline round can pass the correct scope ID to JVM callbacks;
  //   - the deopt bundle / BCI information used by getCallSiteBCI.
  //
  // Return AddedMonomorphicTargets=true if CHA creates or marks at least one
  // new MonomorphicTarget call site that the next inline round should try.
  return {};
}

static MonomorphicTargetDiscoveryResult
runPGORefinement(Module &, ModuleAnalysisManager &) {
  // TODO: Run the PGO refinement pass after CHA. It may use profile data to
  // decide which guarded targets are hot enough to expose as direct calls for
  // the next inline round.
  //
  // Like CHA, PGO must preserve inline-scope-id metadata and deopt bundle / BCI
  // information on every call site it clones or replaces.
  //
  // Return AddedMonomorphicTargets=true if PGO creates or marks at least one
  // new MonomorphicTarget call site that the next inline round should try.
  return {};
}

PreservedAnalyses JeandleInlineDriver::run(Module &M,
                                           ModuleAnalysisManager &MAM) {
  SmallVector<std::pair<Function *, int>, 16> InlineScopes;
  bool Changed = false;

  // The driver owns the inline/CHA/PGO loop. Keeping InlineScopes here lets the
  // future CHA/PGO extension points preserve JVM callback scope IDs across IR
  // rewrites instead of trying to infer scope from a freshly scanned root body.
  //
  // Loop shape:
  //   1. Run one inline round. The round tags every newly exposed call site
  //   with
  //      inline-scope-id metadata.
  //   2. If the inline round did not expose any new call sites, stop.
  //   3. Run CHA, then PGO. Both must propagate inline-scope-id and deopt/BCI
  //      information when they clone or replace calls.
  //   4. If neither CHA nor PGO produced a new MonomorphicTarget call site,
  //      stop; otherwise rescan IR in the next inline round.
  for (;;) {
    InlineRoundResult InlineResult =
        runInlineRound(M, MAM, InlineAccessorsOnly, InlineScopes);
    Changed |= InlineResult.Changed;

    if (!InlineResult.ExposedNewCallSites)
      break;

    MonomorphicTargetDiscoveryResult CHAResult = runCHARefinement(M, MAM);
    Changed |= CHAResult.Changed;

    MonomorphicTargetDiscoveryResult PGOResult = runPGORefinement(M, MAM);
    Changed |= PGOResult.Changed;

    // CHA/PGO may rewrite the root IR and replace CallBase objects exposed by
    // the inline round. Do not carry a cross-pass worklist through this point;
    // the next runInlineRound rescans the root function and should read the
    // preserved inline-scope-id metadata from surviving/generated call sites.
    if (!CHAResult.AddedMonomorphicTargets &&
        !PGOResult.AddedMonomorphicTargets)
      break;
  }

  if (!Changed)
    return PreservedAnalyses::all();

  Function *RootFunction = getRootJavaMethodFunction(M);

  // inline-scope-id is driver-local scheduling state. It is only needed while
  // the driver loop is active so CHA/PGO rewrites can preserve scope IDs for
  // the next inline round. Drop it before leaving the driver to avoid leaking
  // stale scope IDs into later optimizations or a future driver invocation.
  if (RootFunction)
    Changed |= eraseInlineScopeIDs(*RootFunction);

  // Callee IR requested from the JVM is available_externally: it is useful for
  // optimization, but should not remain as a definition after the inline driver
  // is done. If such a method still has uses, delete only its body so existing
  // references stay valid as declarations; otherwise erase the function.
  bool RemovedCalleeIR = eraseAvailableExternallyJavaMethods(M, RootFunction);

  if (RemovedCalleeIR)
    return PreservedAnalyses::none();
  return getInlineRoundPreservedAnalyses(Changed);
}
