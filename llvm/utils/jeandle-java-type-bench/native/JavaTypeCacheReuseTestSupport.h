//===- JavaTypeCacheReuseTestSupport.h - Context reuse fixtures --*- C++
//-*-===//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
#ifndef LLVM_UNITTESTS_IR_JAVATYPECACHEREUSETESTSUPPORT_H
#define LLVM_UNITTESTS_IR_JAVATYPECACHEREUSETESTSUPPORT_H

#include "llvm/Analysis/AssumptionCache.h"
#include "llvm/Analysis/Jeandle/CachedJavaType.h"
#include "llvm/Analysis/Jeandle/LVINullEdgeOracle.h"
#include "llvm/Analysis/LazyValueInfo.h"
#include "llvm/IR/Dominators.h"
#include "llvm/IR/IRBuilder.h"
#include "llvm/IR/Jeandle/VMCallback.h"
#include "llvm/IR/Module.h"
#include <memory>
#include <string>

namespace llvm::jeandle::cache_reuse_test {
struct VMEnvironment {
  VMCallbacks Saved{};
  VMEnvironment() {
    if (const auto *Old = getVMCallbacks())
      Saved = *Old;
    VMCallbacks CB{};
    CB.IsSubtype = [](uintptr_t A, uintptr_t B) { return A == B || B == 1; };
    CB.IsInterface = [](uintptr_t) { return false; };
    CB.IsEffectivelyFinal = [](uintptr_t) { return false; };
    CB.GetSecondarySupers = [](uintptr_t) { return std::vector<uintptr_t>{}; };
    CB.GetCommonSuperKlass = [](uintptr_t A, uintptr_t B) {
      return A == B ? A : uintptr_t(1);
    };
    registerVMCallbacks(CB);
  }
  ~VMEnvironment() { registerVMCallbacks(Saved); }
};

// No java-klass base attribute: a successful query must recover the guard fact.
struct Fixture {
  LLVMContext C;
  std::unique_ptr<Module> M;
  Function *F = nullptr;
  Value *Obj = nullptr;
  CallInst *Guard = nullptr;
  BinaryOperator *Noise = nullptr;
  SmallVector<Instruction *, 16> Contexts;
  DominatorTree DT;
  std::unique_ptr<AssumptionCache> AC;
  std::unique_ptr<LazyValueInfo> LVI;
  JavaTypeCache Cache;
  CachedJavaTypeQueryInfo Last;
  uint64_t OracleCalls = 0;
  bool CountOracle;

  Constant *klass(unsigned K) {
    return ConstantExpr::getIntToPtr(ConstantInt::get(Type::getInt64Ty(C), K),
                                     PointerType::get(C, 0));
  }
  Fixture(bool Count = true, unsigned Depth = 32, unsigned Width = 16)
      : M(std::make_unique<Module>("context-reuse", C)), CountOracle(Count) {
    auto *Ptr = PointerType::get(C, 0);
    F = Function::Create(FunctionType::get(Type::getVoidTy(C),
                                           {Ptr, Type::getInt32Ty(C)}, false),
                         Function::ExternalLinkage, "test", *M);
    Obj = F->getArg(0);
    Obj->setName("obj");
    auto *Check = Function::Create(
        FunctionType::get(Type::getInt1Ty(C), {Ptr, Ptr}, false),
        Function::ExternalLinkage, "jeandle.check_instanceof", *M);
    Check->addParamAttr(1, Attribute::NonNull);
    auto *Entry = BasicBlock::Create(C, "entry", F);
    auto *GuardBB = BasicBlock::Create(C, "guard", F);
    auto *Fail = BasicBlock::Create(C, "fail", F);
    SmallVector<BasicBlock *, 64> Blocks;
    for (unsigned I = 0; I != Depth + Width; ++I)
      Blocks.push_back(BasicBlock::Create(C, "path" + std::to_string(I), F));
    BranchInst::Create(GuardBB, Entry);
    IRBuilder<> B(GuardBB);
    Guard = B.CreateCall(Check, {klass(22), Obj}, "check");
    B.CreateCondBr(Guard, Blocks.front(), Fail);
    ReturnInst::Create(C, Fail);
    for (unsigned I = 0; I != Blocks.size(); ++I) {
      if (I + 1 != Blocks.size())
        BranchInst::Create(Blocks[I + 1], Blocks[I]);
      else
        ReturnInst::Create(C, Blocks[I]);
      if (I >= Depth)
        Contexts.push_back(Blocks[I]->getTerminator());
    }
    Noise = BinaryOperator::CreateAdd(
        F->getArg(1), ConstantInt::get(Type::getInt32Ty(C), 1), "unrelated",
        Contexts.front()->getIterator());
    DT.recalculate(*F);
    AC = std::make_unique<AssumptionCache>(*F);
    LVI = std::make_unique<LazyValueInfo>(AC.get(), &M->getDataLayout());
  }
  JavaType query(Instruction *Ctx) {
    LVINullEdgeOracle Oracle{*LVI};
    if (!CountOracle)
      return getCachedJavaType(Obj, &DT, Ctx, Oracle, Cache, Last);
    auto Counted = [&](Value *V, BasicBlock *From, BasicBlock *To) {
      ++OracleCalls;
      return Oracle(V, From, To);
    };
    return getCachedJavaType(Obj, &DT, Ctx, Counted, Cache, Last);
  }
  // A completely fresh dependency set, not the query's warmed DT/LVI/cache.
  JavaType fresh(Instruction *Ctx) {
    DominatorTree FreshDT(*F);
    AssumptionCache FreshAC(*F);
    LazyValueInfo FreshLVI(&FreshAC, &M->getDataLayout());
    LVINullEdgeOracle Oracle{FreshLVI};
    JavaTypeCache FreshCache;
    CachedJavaTypeQueryInfo Info;
    return getCachedJavaType(Obj, &FreshDT, Ctx, Oracle, FreshCache, Info);
  }
  void reset() {
    Cache.clear();
    LVI->clear();
    Guard->setArgOperand(0, klass(22));
    Noise->setOperand(1, ConstantInt::get(Type::getInt32Ty(C), 1));
    OracleCalls = 0;
  }
  JavaTypeCacheInvalidationInfo notify(Value *V, bool Full) {
    if (!Full)
      return Cache.invalidate({V});
    JavaTypeCacheInvalidationInfo Info;
    Info.BaseRemoved = Cache.baseSize();
    Info.FactsRemoved = Cache.pathFactsSize();
    Info.FinalRemoved = Cache.finalTypesSize();
    Info.FullClear = true;
    Cache.clear();
    return Info;
  }
  JavaTypeCacheInvalidationInfo editNoise(bool Full = false) {
    auto Info = notify(Noise, Full);
    Noise->setOperand(1, ConstantInt::get(Type::getInt32Ty(C), 2));
    return Info;
  }
  JavaTypeCacheInvalidationInfo editGuard(bool Full = false) {
    auto Info = notify(Guard, Full); // Notify while the old use graph is live.
    Guard->setArgOperand(0, klass(33));
    LVI->clear(); // CFG is unchanged, but the queried analysis must stay fresh.
    return Info;
  }
};
} // namespace llvm::jeandle::cache_reuse_test
#endif
