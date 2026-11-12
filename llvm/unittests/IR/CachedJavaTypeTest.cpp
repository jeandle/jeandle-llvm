//===- CachedJavaTypeTest.cpp - Cached Java type migration tests ----------===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#include "llvm/Analysis/Jeandle/CachedJavaType.h"
#include "llvm/ADT/ScopeExit.h"
#include "llvm/ADT/SmallVector.h"
#include "llvm/Analysis/AssumptionCache.h"
#include "llvm/Analysis/Jeandle/JavaTypeAnalysis.h"
#include "llvm/Analysis/Jeandle/JavaTypeAnalysisStats.h"
#include "llvm/Analysis/Jeandle/LVINullEdgeOracle.h"
#include "llvm/Analysis/LazyValueInfo.h"
#include "llvm/AsmParser/Parser.h"
#include "llvm/IR/Constants.h"
#include "llvm/IR/Dominators.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/Jeandle/VMCallback.h"
#include "llvm/IR/LLVMContext.h"
#include "llvm/IR/Metadata.h"
#include "llvm/IR/Module.h"
#include "llvm/IR/Verifier.h"
#include "llvm/Passes/PassBuilder.h"
#include "llvm/Support/CommandLine.h"
#include "llvm/Support/SourceMgr.h"
#include "llvm/Support/raw_ostream.h"
#include "gtest/gtest.h"
#include <iterator>
#include <memory>
#include <vector>

using namespace llvm;
using namespace llvm::jeandle;

namespace {

class CachedJavaTypeTest : public testing::Test {
protected:
  LLVMContext Context;
  VMCallbacks Saved{};

  void SetUp() override {
    if (const VMCallbacks *CB = getVMCallbacks())
      Saved = *CB;
    VMCallbacks CB{};
    CB.IsInterface = [](uintptr_t) { return false; };
    CB.IsUnverifiedInterface = [](uintptr_t) { return false; };
    CB.IsEffectivelyFinal = [](uintptr_t) { return false; };
    CB.GetSecondarySupers = [](uintptr_t) { return std::vector<uintptr_t>{}; };
    CB.IsSubtype = [](uintptr_t A, uintptr_t B) { return A == B || B == 5; };
    CB.GetCommonSuperKlass = [](uintptr_t A, uintptr_t B) {
      return A == B ? A : uintptr_t(5);
    };
    registerVMCallbacks(CB);
  }

  void TearDown() override { registerVMCallbacks(Saved); }

  std::unique_ptr<Module> parse(StringRef IR) {
    SMDiagnostic Error;
    auto M = parseAssemblyString(IR, Error, Context);
    if (!M) {
      ADD_FAILURE() << Error.getMessage().str();
      return nullptr;
    }
    if (verifyModule(*M, &errs())) {
      ADD_FAILURE() << "Invalid test module";
      return nullptr;
    }
    return M;
  }

  static bool noNullEdge(Value *, BasicBlock *, BasicBlock *) { return false; }

  static Value *returnedValue(Function &F) {
    return cast<ReturnInst>(F.back().getTerminator())->getReturnValue();
  }

  // The original Base/edge regressions observe one query at a time and keep
  // Final disabled, so a Final hit cannot hide work in the layer under test.
  static JavaType query(Value *V, DominatorTree *DT, Instruction *At,
                        IsNullEdgeOracle Oracle, JavaTypeCache &Cache) {
    Cache.setFinalEnabled(false);
    Cache.setPathEnabled(false);
    Cache.setStatsEnabled(true);
    Cache.Base.resetStats();
    return getCachedJavaType(V, DT, At, Oracle, Cache);
  }

  static JavaType query(Value *V, JavaTypeCache &Cache) {
    return query(V, nullptr, nullptr, noNullEdge, Cache);
  }

  static JavaType fresh(Value *V) {
    return getJavaType(V, nullptr, nullptr, noNullEdge);
  }
};

TEST_F(CachedJavaTypeTest, BaseMemoReusesCompletedResultAndOwnsCounters) {
  auto M = parse(R"IR(
    define ptr addrspace(1) @test(
        ptr addrspace(1) "java-klass"="9" "java-klass-exact" %a,
        i1 %pick) {
      %result = select i1 %pick, ptr addrspace(1) %a,
                                ptr addrspace(1) null
      ret ptr addrspace(1) %result
    }
  )IR");
  ASSERT_NE(M, nullptr);
  Value *V = returnedValue(*M->getFunction("test"));
  JavaTypeCache Cache;

  EXPECT_EQ(query(V, Cache), JavaType(9, true));
  EXPECT_EQ(Cache.Base.getStats().Hits, 0U);
  EXPECT_EQ(Cache.Base.getStats().Misses, 1U);
  EXPECT_GE(Cache.baseSize(), 2U);
  size_t Size = Cache.baseSize();

  EXPECT_EQ(query(V, Cache), fresh(V));
  EXPECT_EQ(Cache.Base.getStats().Hits, 1U);
  EXPECT_EQ(Cache.Base.getStats().Misses, 0U);
  EXPECT_EQ(Cache.baseSize(), Size);
}

TEST_F(CachedJavaTypeTest, ClearRefreshesLoadMetadataAndDerivedResult) {
  auto M = parse(R"IR(
    define ptr addrspace(1) @test(ptr %slot, i1 %pick) {
      %loaded = load ptr addrspace(1), ptr %slot,
                     !java-klass !0, !java-klass-exact !1
      %result = select i1 %pick, ptr addrspace(1) %loaded,
                                ptr addrspace(1) null
      ret ptr addrspace(1) %result
    }
    !0 = !{i64 9}
    !1 = !{}
  )IR");
  ASSERT_NE(M, nullptr);
  Function &F = *M->getFunction("test");
  Value *V = returnedValue(F);
  JavaTypeCache Cache;

  EXPECT_EQ(query(V, Cache), JavaType(9, true));
  EXPECT_GE(Cache.baseSize(), 2U);

  Cache.clear();
  EXPECT_EQ(Cache.baseSize(), 0U);
  auto *Load = cast<LoadInst>(&F.front().front());
  Load->setMetadata(
      "java-klass",
      MDNode::get(Context, ConstantAsMetadata::get(ConstantInt::get(
                               Type::getInt64Ty(Context), 22))));
  EXPECT_EQ(query(V, Cache), JavaType(22, true));
  EXPECT_EQ(Cache.Base.getStats().Misses, 1U);
  EXPECT_EQ(query(V, Cache), fresh(V));
  EXPECT_EQ(Cache.Base.getStats().Hits, 1U);
}

TEST_F(CachedJavaTypeTest, CompletedSCCMembersAreReusableInEitherOrder) {
  auto M = parse(R"IR(
    define ptr addrspace(1) @test(
        ptr addrspace(1) "java-klass"="9" "java-klass-exact" %a,
        ptr addrspace(1) "java-klass"="22" "java-klass-exact" %b,
        i1 %again) {
    entry:
      br label %loop
    loop:
      %left = phi ptr addrspace(1) [ %a, %entry ], [ %right, %loop ]
      %right = phi ptr addrspace(1) [ %b, %entry ], [ %left, %loop ]
      br i1 %again, label %loop, label %exit
    exit:
      ret ptr addrspace(1) %left
    }
  )IR");
  ASSERT_NE(M, nullptr);
  auto Loop = std::next(M->getFunction("test")->begin());
  Value *Left = &Loop->front();
  Value *Right = &*std::next(Loop->begin());
  for (bool Reverse : {false, true}) {
    SCOPED_TRACE(Reverse);
    Value *First = Reverse ? Right : Left;
    Value *Second = Reverse ? Left : Right;
    JavaTypeCache Cache;

    EXPECT_EQ(query(First, Cache), JavaType(5, false));
    EXPECT_EQ(query(First, Cache), fresh(First));
    size_t Size = Cache.baseSize();
    EXPECT_EQ(query(Second, Cache), fresh(Second));
    EXPECT_EQ(Cache.Base.getStats().Hits, 1U);
    EXPECT_EQ(Cache.Base.getStats().Misses, 0U);
    EXPECT_EQ(Cache.baseSize(), Size);
  }
}

TEST_F(CachedJavaTypeTest, FreezeOfPossiblyPoisonOperandRemainsUnknown) {
  auto M = parse(R"IR(
    define ptr addrspace(1) @test(
        ptr addrspace(1) "java-klass"="9" "java-klass-exact" %a) {
      %result = freeze ptr addrspace(1) %a
      ret ptr addrspace(1) %result
    }
  )IR");
  ASSERT_NE(M, nullptr);
  Function &F = *M->getFunction("test");
  Value *V = returnedValue(F);
  JavaTypeCache Cache;

  EXPECT_EQ(query(F.getArg(0), Cache), JavaType(9, true));
  EXPECT_TRUE(query(V, Cache).isUnknown());
  EXPECT_EQ(query(V, Cache), fresh(V));
  EXPECT_EQ(Cache.Base.getStats().Hits, 1U);
  DominatorTree DT(F);
  EXPECT_EQ(query(V, &DT, F.back().getTerminator(), noNullEdge, Cache),
            getJavaType(V, &DT, F.back().getTerminator(), noNullEdge));
}

TEST_F(CachedJavaTypeTest, FreezeOfDefinedOperandRetainsType) {
  auto M = parse(R"IR(
    define ptr addrspace(1) @test(
        ptr addrspace(1) noundef "java-klass"="9" "java-klass-exact" %a) {
      %result = freeze ptr addrspace(1) %a
      ret ptr addrspace(1) %result
    }
  )IR");
  ASSERT_NE(M, nullptr);
  Function &F = *M->getFunction("test");
  Value *V = returnedValue(F);
  JavaTypeCache Cache;

  EXPECT_EQ(query(V, Cache), JavaType(9, true));
  EXPECT_EQ(query(V, Cache), fresh(V));
  DominatorTree DT(F);
  EXPECT_EQ(query(V, &DT, F.back().getTerminator(), noNullEdge, Cache),
            getJavaType(V, &DT, F.back().getTerminator(), noNullEdge));
}

TEST_F(CachedJavaTypeTest,
       SharedEngineKeepsFreezeProofsWithoutPublishingFinal) {
  auto M = parse(R"IR(
    define void @test(ptr "java-klass"="9" %maybe,
                      ptr noundef "java-klass"="22" %defined) {
      %uncertain = freeze ptr %maybe
      %stable = freeze ptr %defined
      ret void
    }
  )IR");
  ASSERT_NE(M, nullptr);
  Function &F = *M->getFunction("test");
  DominatorTree DT(F);
  Instruction *Uncertain = &F.front().front();
  Instruction *Stable = Uncertain->getNextNode();
  Instruction *At = F.front().getTerminator();
  JavaTypeCache Cache(F, JavaTypeCache::Mode::StableOracleEpoch);
  Cache.setStatsEnabled(true);

  EXPECT_TRUE(getJavaType(Uncertain, &DT, At, noNullEdge).isUnknown());
  EXPECT_TRUE(getJavaType(Uncertain, &DT, At, noNullEdge, Cache).isUnknown());
  EXPECT_EQ(Cache.finalTypesSize(), 0U);
  EXPECT_TRUE(
      getCachedJavaType(Uncertain, &DT, At, noNullEdge, Cache).isUnknown());
  // The possibly-poison input retains its own type, not the frozen result's
  // unknown answer. The shared solver leaves Final publication to the wrapper.
  EXPECT_EQ(getJavaType(F.getArg(0), &DT, At, noNullEdge, Cache),
            JavaType(9, false));
  EXPECT_EQ(Cache.finalTypesSize(), 1U);
  EXPECT_EQ(getCachedJavaType(F.getArg(0), &DT, At, noNullEdge, Cache),
            JavaType(9, false));
  EXPECT_EQ(getJavaType(Stable, &DT, At, noNullEdge), JavaType(22, false));
  EXPECT_EQ(getJavaType(Stable, &DT, At, noNullEdge, Cache),
            JavaType(22, false));
  EXPECT_EQ(Cache.finalTypesSize(), 2U);
  EXPECT_EQ(getCachedJavaType(Stable, &DT, At, noNullEdge, Cache),
            JavaType(22, false));
  EXPECT_EQ(getCachedJavaType(Stable, &DT, At, noNullEdge, Cache),
            JavaType(22, false));
  EXPECT_TRUE(
      getCachedJavaType(Uncertain, &DT, At, noNullEdge, Cache).isUnknown());
  EXPECT_EQ(Cache.finalTypesSize(), 3U);
  EXPECT_EQ(Cache.Final.getStats().Hits, 2U);
  EXPECT_EQ(Cache.Final.getStats().Misses, 3U);
}

TEST_F(CachedJavaTypeTest, SharedEngineLeavesContextFinalsToCachedWrapper) {
  auto M = parse(R"IR(
    declare i1 @jeandle.check_instanceof(ptr, ptr nonnull)
    define void @test(ptr %obj) {
    entry:
      %check = call i1 @jeandle.check_instanceof(
          ptr inttoptr(i64 9 to ptr), ptr %obj)
      br i1 %check, label %accepted, label %rejected
    accepted:
      ret void
    rejected:
      ret void
    }
  )IR");
  ASSERT_NE(M, nullptr);
  Function &F = *M->getFunction("test");
  DominatorTree DT(F);
  Value *Obj = F.getArg(0);
  Instruction *BeforeGuard = F.front().getTerminator();
  Instruction *Accepted = std::next(F.begin())->getTerminator();
  JavaTypeCache Cache(F, JavaTypeCache::Mode::StableOracleEpoch);
  Cache.setStatsEnabled(true);

  EXPECT_TRUE(getJavaType(Obj, &DT, BeforeGuard, noNullEdge).isUnknown());
  EXPECT_EQ(getJavaType(Obj, &DT, Accepted, noNullEdge), JavaType(9, false));
  EXPECT_EQ(Cache.finalTypesSize(), 0U);
  EXPECT_TRUE(
      getJavaType(Obj, &DT, BeforeGuard, noNullEdge, Cache).isUnknown());
  EXPECT_EQ(Cache.finalTypesSize(), 0U);
  EXPECT_EQ(getCachedJavaType(Obj, &DT, Accepted, noNullEdge, Cache),
            JavaType(9, false));
  EXPECT_EQ(getJavaType(Obj, &DT, Accepted, noNullEdge, Cache),
            JavaType(9, false));
  EXPECT_EQ(Cache.finalTypesSize(), 1U);
  EXPECT_EQ(Cache.Final.getStats().Hits, 0U);
  EXPECT_EQ(Cache.Final.getStats().Misses, 1U);
  EXPECT_TRUE(
      getCachedJavaType(Obj, &DT, BeforeGuard, noNullEdge, Cache).isUnknown());
  EXPECT_EQ(getCachedJavaType(Obj, &DT, Accepted, noNullEdge, Cache),
            JavaType(9, false));
  EXPECT_TRUE(
      getCachedJavaType(Obj, &DT, BeforeGuard, noNullEdge, Cache).isUnknown());
  EXPECT_EQ(Cache.finalTypesSize(), 2U);
  EXPECT_EQ(Cache.Final.getStats().Hits, 2U);
  EXPECT_EQ(Cache.Final.getStats().Misses, 2U);
}

TEST_F(CachedJavaTypeTest, UncachedEntryIgnoresExternalMemoAfterMetadataEdit) {
  auto M = parse(R"IR(
    define ptr @test(ptr %slot) {
      %loaded = load ptr, ptr %slot, !java-klass !0
      ret ptr %loaded
    }
    !0 = !{i64 9}
  )IR");
  ASSERT_NE(M, nullptr);
  Function &F = *M->getFunction("test");
  auto *Loaded = cast<LoadInst>(&F.front().front());
  JavaTypeCache Cache(F);
  EXPECT_EQ(getJavaType(Loaded, nullptr, nullptr, noNullEdge, Cache),
            JavaType(9, false));
  ASSERT_TRUE(Cache.Base.storage().contains(Loaded));

  // Deliberately leave the external memo untouched. Only uncached queries
  // are allowed after this edit until invalidate() below.
  Loaded->setMetadata(
      "java-klass",
      MDNode::get(Context, ConstantAsMetadata::get(ConstantInt::get(
                               Type::getInt64Ty(Context), 22))));
  EXPECT_EQ(getJavaType(Loaded, nullptr, nullptr, noNullEdge),
            JavaType(22, false));
  EXPECT_EQ(Cache.Base.storage().lookup(Loaded), JavaType(9, false));
  Cache.invalidate({Loaded});
  EXPECT_EQ(getCachedJavaType(Loaded, nullptr, nullptr, noNullEdge, Cache),
            JavaType(22, false));
}

TEST_F(CachedJavaTypeTest, ReturnedCallKeepsItsIndependentTypeSeed) {
  auto M = parse(R"IR(
    declare ptr addrspace(1) @identity(ptr addrspace(1) returned)
    define ptr addrspace(1) @test(ptr addrspace(1) %a) {
      %result = call "java-klass"="9" "java-klass-exact" ptr addrspace(1)
                     @identity(ptr addrspace(1) %a)
      ret ptr addrspace(1) %result
    }
  )IR");
  ASSERT_NE(M, nullptr);
  Function &F = *M->getFunction("test");
  Value *V = returnedValue(F);
  JavaTypeCache Cache;

  EXPECT_TRUE(query(F.getArg(0), Cache).isUnknown());
  EXPECT_EQ(query(V, Cache), JavaType(9, true));
  EXPECT_EQ(query(V, Cache), fresh(V));
  EXPECT_EQ(Cache.Base.getStats().Hits, 1U);
  DominatorTree DT(F);
  EXPECT_EQ(query(V, &DT, F.back().getTerminator(), noNullEdge, Cache),
            getJavaType(V, &DT, F.back().getTerminator(), noNullEdge));
}

TEST_F(CachedJavaTypeTest, ContextFactsDoNotLeakBetweenQueriesOrIntoBase) {
  auto M = parse(R"IR(
    declare i1 @jeandle.check_instanceof(ptr, ptr addrspace(1) nonnull)
    define ptr addrspace(1) @test(ptr addrspace(1) %a) {
    entry:
      %check = call i1 @jeandle.check_instanceof(
          ptr inttoptr (i64 9 to ptr), ptr addrspace(1) %a)
      br i1 %check, label %accepted, label %rejected
    accepted:
      ret ptr addrspace(1) %a
    rejected:
      ret ptr addrspace(1) %a
    }
  )IR");
  ASSERT_NE(M, nullptr);
  Function &F = *M->getFunction("test");
  Value *V = F.getArg(0);
  Instruction *Accepted = std::next(F.begin())->getTerminator();
  Instruction *Rejected = F.back().getTerminator();
  DominatorTree DT(F);
  for (bool Reverse : {false, true}) {
    SCOPED_TRACE(Reverse);
    JavaTypeCache Cache;

    Instruction *First = Reverse ? Rejected : Accepted;
    Instruction *Second = Reverse ? Accepted : Rejected;
    bool Cold = true;
    for (Instruction *At : {First, Second, First}) {
      JavaType Result = query(V, &DT, At, noNullEdge, Cache);
      EXPECT_EQ(Result, getJavaType(V, &DT, At, noNullEdge));
      EXPECT_EQ(Result.Klass, At == Accepted ? 9U : 0U);
      EXPECT_EQ(Cache.Base.getStats().Hits, Cold ? 0U : 1U);
      EXPECT_EQ(Cache.Base.getStats().Misses, Cold ? 1U : 0U);
      Cold = false;
    }
    EXPECT_TRUE(query(V, Cache).isUnknown());
    EXPECT_EQ(Cache.Base.getStats().Hits, 1U);
    EXPECT_EQ(query(V, Cache), fresh(V));
  }
}

TEST_F(CachedJavaTypeTest, SharpenKeepsEdgeFactsSeparateFromWarmBaseMemo) {
  auto M = parse(R"IR(
    declare i1 @jeandle.check_instanceof(ptr, ptr addrspace(1) nonnull)
    define ptr addrspace(1) @test(
        ptr addrspace(1) "java-klass"="5" %a) {
    entry:
      %first = call i1 @jeandle.check_instanceof(
          ptr inttoptr (i64 22 to ptr), ptr addrspace(1) %a)
      br i1 %first, label %bypass, label %checked
    checked:
      %second = call i1 @jeandle.check_instanceof(
          ptr inttoptr (i64 9 to ptr), ptr addrspace(1) %a)
      br i1 %second, label %accepted, label %rejected
    bypass:
      br label %accepted
    accepted:
      %yes = phi ptr addrspace(1) [ %a, %checked ], [ %a, %bypass ]
      ret ptr addrspace(1) %yes
    rejected:
      %no = phi ptr addrspace(1) [ %a, %checked ]
      ret ptr addrspace(1) %no
    }
  )IR");
  ASSERT_NE(M, nullptr);
  Function &F = *M->getFunction("test");
  Value *V = F.getArg(0);
  BasicBlock *Checked = &*std::next(F.begin());
  BasicBlock *Accepted = &*std::next(F.begin(), 3);
  BasicBlock *Rejected = &F.back();
  DominatorTree DT(F);
  JavaTypeCache Cache;

  EXPECT_EQ(query(V, Cache), JavaType(5, false));
  EXPECT_EQ(query(V, &DT, Rejected->getTerminator(), noNullEdge, Cache),
            getJavaType(V, &DT, Rejected->getTerminator(), noNullEdge));

  // The predecessor's failed check and the current edge's failed check both
  // contribute, but the cached attribute-derived base must not enter sharpen.
  JavaType Denied =
      sharpen(V, Checked->getTerminator(), DT, Rejected, noNullEdge);
  EXPECT_EQ(Denied.Klass, 0U);
  EXPECT_FALSE(Denied.Exact);
  EXPECT_TRUE(Denied.Interfaces.empty());
  EXPECT_EQ(Denied.ExcludedKlasses.size(), 2U);
  EXPECT_TRUE(Denied.ExcludedKlasses.contains(22));
  EXPECT_TRUE(Denied.ExcludedKlasses.contains(9));

  JavaType Allowed =
      sharpen(V, Checked->getTerminator(), DT, Accepted, noNullEdge);
  EXPECT_EQ(Allowed.Klass, 9U);
  EXPECT_FALSE(Allowed.Exact);
  EXPECT_EQ(query(V, Cache), JavaType(5, false));
  EXPECT_EQ(Cache.Base.getStats().Hits, 1U);
}

TEST_F(CachedJavaTypeTest, SharedBudgetChangesRebuildQueryLocalFacts) {
  auto M = parse(R"IR(
    declare i1 @jeandle.check_instanceof(ptr, ptr addrspace(1) nonnull)
    define ptr addrspace(1) @test(ptr addrspace(1) %a) {
    entry:
      %check = call i1 @jeandle.check_instanceof(
          ptr inttoptr (i64 9 to ptr), ptr addrspace(1) %a)
      br i1 %check, label %accepted, label %rejected
    accepted:
      br label %query
    query:
      ret ptr addrspace(1) %a
    rejected:
      ret ptr addrspace(1) %a
    }
  )IR");
  ASSERT_NE(M, nullptr);
  auto *Option =
      cl::getRegisteredOptions().lookup("jeandle-max-facts-join-blocks");
  ASSERT_NE(Option, nullptr);
  auto &Budget = *static_cast<cl::opt<unsigned> *>(Option);
  unsigned SavedBudget = Budget;
  auto RestoreBudget = make_scope_exit([&] { Budget = SavedBudget; });

  Function &F = *M->getFunction("test");
  Value *V = F.getArg(0);
  Instruction *At = std::next(F.begin(), 2)->getTerminator();
  DominatorTree DT(F);
  JavaTypeCache Cache;

  for (unsigned Limit : {1U, 128U, 1U, 128U}) {
    SCOPED_TRACE(Limit);
    Budget = Limit;
    JavaType Result = query(V, &DT, At, noNullEdge, Cache);
    EXPECT_EQ(Result, getJavaType(V, &DT, At, noNullEdge));
    EXPECT_EQ(Result, Limit == 1 ? JavaType() : JavaType(9, false));
    EXPECT_GT(Cache.baseSize(), 0U);
  }
  // The same Base memo survives all four queries; neither a truncated result
  // nor the later complete path facts may become persistent base knowledge.
  EXPECT_TRUE(query(V, Cache).isUnknown());
  EXPECT_EQ(Cache.Base.getStats().Hits, 1U);
}

static Instruction *findBaseTestInstruction(Function &F, StringRef Name) {
  for (BasicBlock &BB : F)
    for (Instruction &I : BB)
      if (I.getName() == Name)
        return &I;
  return nullptr;
}

TEST_F(CachedJavaTypeTest,
       InvalidateTraversesUncachedIntegerProofDependencies) {
  auto M = parse(R"IR(
    define ptr addrspace(1) @test(
        ptr addrspace(1) noundef "java-klass"="9" "java-klass-exact" %a,
        ptr addrspace(1) noundef "java-klass"="9" "java-klass-exact" %b,
        ptr addrspace(1) "java-klass"="22" "java-klass-exact" %unrelated,
        i32 noundef %n) {
      %sum = add i32 %n, 1
      %condition = icmp eq i32 %sum, 0
      %selected = select i1 %condition, ptr addrspace(1) %a,
                                       ptr addrspace(1) %b
      %result = freeze ptr addrspace(1) %selected
      ret ptr addrspace(1) %result
    }
  )IR");
  ASSERT_NE(M, nullptr);
  Function &F = *M->getFunction("test");
  auto *Sum = cast<BinaryOperator>(findBaseTestInstruction(F, "sum"));
  Value *V = returnedValue(F);
  JavaTypeCache Cache;

  EXPECT_EQ(query(V, Cache), JavaType(9, true));
  EXPECT_EQ(query(F.getArg(2), Cache), JavaType(22, true));

  auto Invalidated = Cache.invalidate({Sum});
  EXPECT_FALSE(Invalidated.FullClear);
  EXPECT_GE(Invalidated.BaseRemoved, 2U);
  Sum->setHasNoSignedWrap(true);

  EXPECT_TRUE(query(V, Cache).isUnknown());
  EXPECT_GT(Cache.Base.getStats().Misses, 0U);
  EXPECT_EQ(query(V, Cache), fresh(V));
  EXPECT_EQ(query(F.getArg(2), Cache), JavaType(22, true));
  EXPECT_EQ(Cache.Base.getStats().Hits, 1U);
  EXPECT_FALSE(verifyModule(*M, &errs()));
}

TEST_F(CachedJavaTypeTest, ReturnedCallSeedDoesNotHideItsOperandDependency) {
  auto M = parse(R"IR(
    declare ptr addrspace(1) @identity(ptr addrspace(1) returned)
    define ptr addrspace(1) @test(
        ptr addrspace(1) "java-klass"="9" "java-klass-exact" %a,
        ptr addrspace(1) "java-klass"="9" "java-klass-exact" %unrelated) {
      %result = call "java-klass"="5" ptr addrspace(1)
                     @identity(ptr addrspace(1) %a)
      ret ptr addrspace(1) %result
    }
  )IR");
  ASSERT_NE(M, nullptr);
  Function &F = *M->getFunction("test");
  Value *V = returnedValue(F);
  JavaTypeCache Cache;

  EXPECT_EQ(query(V, Cache), JavaType(9, true));
  EXPECT_EQ(query(F.getArg(1), Cache), JavaType(9, true));

  auto Invalidated = Cache.invalidate({F.getArg(0)});
  EXPECT_FALSE(Invalidated.FullClear);
  EXPECT_GE(Invalidated.BaseRemoved, 2U);
  F.addParamAttr(0, Attribute::get(Context, "java-klass", "22"));

  EXPECT_EQ(query(V, Cache), JavaType(22, true));
  EXPECT_EQ(query(V, Cache), fresh(V));
  EXPECT_EQ(query(F.getArg(1), Cache), JavaType(9, true));
  EXPECT_EQ(Cache.Base.getStats().Hits, 1U);
  EXPECT_FALSE(verifyModule(*M, &errs()));
}

TEST_F(CachedJavaTypeTest, InvalidateSCCMemberRecomputesWholeDependentCycle) {
  auto M = parse(R"IR(
    define ptr addrspace(1) @test(
        ptr addrspace(1) "java-klass"="9" "java-klass-exact" %a,
        ptr addrspace(1) "java-klass"="22" "java-klass-exact" %b,
        i1 %again) {
    entry:
      br label %loop
    loop:
      %left = phi ptr addrspace(1) [ %a, %entry ], [ %right, %loop ]
      %right = phi ptr addrspace(1) [ %b, %entry ], [ %left, %loop ]
      br i1 %again, label %loop, label %exit
    exit:
      ret ptr addrspace(1) %left
    }
  )IR");
  ASSERT_NE(M, nullptr);
  Function &F = *M->getFunction("test");
  auto *Left = cast<PHINode>(findBaseTestInstruction(F, "left"));
  auto *Right = cast<PHINode>(findBaseTestInstruction(F, "right"));
  JavaTypeCache Cache;

  EXPECT_EQ(query(Left, Cache), JavaType(5, false));
  EXPECT_EQ(query(Right, Cache), JavaType(5, false));

  auto Invalidated = Cache.invalidate({Right});
  EXPECT_FALSE(Invalidated.FullClear);
  EXPECT_EQ(Invalidated.BaseRemoved, 2U);
  Right->setIncomingValue(0, F.getArg(0));

  EXPECT_EQ(query(Left, Cache), JavaType(9, true));
  EXPECT_EQ(query(Left, Cache), fresh(Left));
  EXPECT_EQ(query(Right, Cache), fresh(Right));
  EXPECT_EQ(Cache.Base.getStats().Hits, 1U);
  EXPECT_EQ(query(F.getArg(1), Cache), JavaType(22, true));
  EXPECT_EQ(Cache.Base.getStats().Hits, 1U);
  EXPECT_FALSE(verifyModule(*M, &errs()));
}

TEST_F(CachedJavaTypeTest, CFGEdgeRemovalInvalidatesOnlyExplicitPhiClosure) {
  auto M = parse(R"IR(
    define ptr addrspace(1) @test(
        ptr addrspace(1) "java-klass"="9" "java-klass-exact" %a,
        ptr addrspace(1) "java-klass"="22" "java-klass-exact" %b,
        i1 %pick) {
    entry:
      %stable = select i1 %pick, ptr addrspace(1) %a,
                                ptr addrspace(1) null
      br i1 %pick, label %left, label %right
    left:
      br label %merge
    right:
      br label %merge
    merge:
      %result = phi ptr addrspace(1) [ %a, %left ], [ %b, %right ]
      ret ptr addrspace(1) %result
    }
  )IR");
  ASSERT_NE(M, nullptr);
  Function &F = *M->getFunction("test");
  auto *Phi = cast<PHINode>(returnedValue(F));
  Value *Stable = findBaseTestInstruction(F, "stable");
  BasicBlock *Right = &*std::next(F.begin(), 2);
  Instruction *RightBranch = Right->getTerminator();
  JavaTypeCache Cache;

  EXPECT_EQ(query(Phi, Cache), JavaType(5, false));
  EXPECT_EQ(query(Stable, Cache), JavaType(9, true));

  // Redirect one predecessor to return directly. The PHI edit, rather than
  // the predecessor terminator's SSA users, identifies the affected base key.
  auto Invalidated = Cache.invalidate({RightBranch, Phi});
  EXPECT_FALSE(Invalidated.FullClear);
  EXPECT_EQ(Invalidated.BaseRemoved, 1U);
  ReturnInst::Create(Context, F.getArg(1), RightBranch->getIterator());
  RightBranch->eraseFromParent();
  Phi->removeIncomingValue(Right, false);

  EXPECT_EQ(query(Phi, Cache), JavaType(9, true));
  EXPECT_EQ(query(Phi, Cache), fresh(Phi));
  EXPECT_EQ(query(Stable, Cache), JavaType(9, true));
  EXPECT_EQ(Cache.Base.getStats().Hits, 1U);
  EXPECT_FALSE(verifyModule(*M, &errs()));
}

TEST_F(CachedJavaTypeTest, PureBlockSplitKeepsUnchangedBaseResult) {
  auto M = parse(R"IR(
    define ptr addrspace(1) @test(
        ptr addrspace(1) "java-klass"="9" "java-klass-exact" %a,
        i1 %pick) {
      %result = select i1 %pick, ptr addrspace(1) %a,
                                ptr addrspace(1) null
      ret ptr addrspace(1) %result
    }
  )IR");
  ASSERT_NE(M, nullptr);
  Function &F = *M->getFunction("test");
  Value *V = returnedValue(F);
  JavaTypeCache Cache;

  EXPECT_EQ(query(V, Cache), JavaType(9, true));
  size_t Size = Cache.baseSize();

  // The new edge does not change any type/proof operand or destroy a value.
  F.front().splitBasicBlock(F.front().getTerminator()->getIterator(), "split");

  EXPECT_EQ(query(V, Cache), fresh(V));
  EXPECT_EQ(Cache.Base.getStats().Hits, 1U);
  EXPECT_EQ(Cache.baseSize(), Size);
  EXPECT_FALSE(verifyModule(*M, &errs()));
}

TEST_F(CachedJavaTypeTest, NotifyBeforeRAUWAndDeleteKeepsUnrelatedBaseEntries) {
  auto M = parse(R"IR(
    define ptr addrspace(1) @test(
        ptr addrspace(1) "java-klass"="9" "java-klass-exact" %a,
        ptr addrspace(1) "java-klass"="22" "java-klass-exact" %b,
        i1 %pick) {
      %old = select i1 %pick, ptr addrspace(1) %a,
                             ptr addrspace(1) null
      %result = getelementptr i8, ptr addrspace(1) %old, i64 0
      ret ptr addrspace(1) %result
    }
  )IR");
  ASSERT_NE(M, nullptr);
  Function &F = *M->getFunction("test");
  Instruction *Old = findBaseTestInstruction(F, "old");
  Value *V = returnedValue(F);
  JavaTypeCache Cache;

  EXPECT_EQ(query(V, Cache), JavaType(9, true));
  EXPECT_EQ(query(F.getArg(1), Cache), JavaType(22, true));

  auto Invalidated = Cache.invalidate({Old});
  EXPECT_FALSE(Invalidated.FullClear);
  EXPECT_EQ(Invalidated.BaseRemoved, 2U);
  Old->replaceAllUsesWith(F.getArg(1));
  Old->eraseFromParent();

  EXPECT_EQ(query(V, Cache), JavaType(22, true));
  EXPECT_EQ(query(V, Cache), fresh(V));
  EXPECT_EQ(query(F.getArg(0), Cache), JavaType(9, true));
  EXPECT_EQ(Cache.Base.getStats().Hits, 1U);
  EXPECT_FALSE(verifyModule(*M, &errs()));
}

TEST_F(CachedJavaTypeTest, CalleeAttributeMutationUsesConservativeFallback) {
  auto M = parse(R"IR(
    declare ptr addrspace(1) @identity(ptr addrspace(1) returned)
    define ptr addrspace(1) @test(
        ptr addrspace(1) "java-klass"="9" "java-klass-exact" %a) {
      %result = call ptr addrspace(1) @identity(ptr addrspace(1) %a)
      ret ptr addrspace(1) %result
    }
  )IR");
  ASSERT_NE(M, nullptr);
  Function &F = *M->getFunction("test");
  Function *Callee = M->getFunction("identity");
  Value *V = returnedValue(F);
  JavaTypeCache Cache;

  EXPECT_EQ(query(V, Cache), JavaType(9, true));

  auto Invalidated = Cache.invalidate({Callee});
  EXPECT_TRUE(Invalidated.FullClear);
  EXPECT_EQ(Cache.baseSize(), 0U);
  Callee->removeParamAttr(0, Attribute::Returned);

  EXPECT_TRUE(query(V, Cache).isUnknown());
  EXPECT_EQ(query(V, Cache), fresh(V));
  EXPECT_FALSE(verifyModule(*M, &errs()));
}

TEST_F(CachedJavaTypeTest, DiagnosticsDistinguishSharedInputsFromRootHits) {
  auto M = parse(R"IR(
    define ptr addrspace(1) @test(
        ptr addrspace(1) "java-klass"="9" %a, i1 %pick) {
      %shared = select i1 %pick, ptr addrspace(1) %a,
                                ptr addrspace(1) null
      %first = getelementptr i8, ptr addrspace(1) %shared, i64 0
      %second = getelementptr i8, ptr addrspace(1) %shared, i64 0
      ret ptr addrspace(1) %second
    }
  )IR");
  ASSERT_NE(M, nullptr);
  Function &F = *M->getFunction("test");
  Value *First = findBaseTestInstruction(F, "first");
  Value *Second = returnedValue(F);
  JavaTypeCache Cache;

  Cache.setDetailedStatsEnabled(true);
  const auto &D = Cache.Base.getStats();
  EXPECT_EQ(query(First, nullptr, nullptr, noNullEdge, Cache), fresh(First));
  EXPECT_EQ(Cache.Base.getStats().Misses, 1U);
  EXPECT_EQ(D.NodesEvaluated, 3U);
  EXPECT_EQ(D.InputMisses, 2U);
  EXPECT_EQ(D.PriorQueryHits, 0U);
  EXPECT_EQ(D.EntriesAdded, 3U);

  // A different root still reuses its completed shared dependency.
  EXPECT_EQ(query(Second, nullptr, nullptr, noNullEdge, Cache), fresh(Second));
  EXPECT_EQ(Cache.Base.getStats().Hits, 0U);
  EXPECT_EQ(Cache.Base.getStats().Misses, 1U);
  EXPECT_EQ(D.InputHits, 1U);
  EXPECT_EQ(D.InputMisses, 0U);
  EXPECT_EQ(D.PriorQueryHits, 1U);
  EXPECT_EQ(D.CurrentQueryHits, 0U);
  EXPECT_EQ(D.NodesEvaluated, 1U);
  EXPECT_EQ(D.EntriesAdded, 1U);

  // Contextual queries must expose Base reuse too. Non-exact base forces the
  // value dimension to walk the GEP, but the entry select reuses Base without
  // querying its argument again. Neither needs Base evaluation.
  DominatorTree DT(F);
  EXPECT_EQ(query(Second, &DT, F.back().getTerminator(), noNullEdge, Cache),
            getJavaType(Second, &DT, F.back().getTerminator(), noNullEdge));
  EXPECT_EQ(Cache.Base.getStats().Hits, 2U);
  EXPECT_EQ(Cache.Base.getStats().Misses, 0U);
  EXPECT_EQ(D.PriorQueryHits, 2U);
  EXPECT_EQ(D.NodesEvaluated, 0U);
  EXPECT_EQ(D.EntriesAdded, 0U);

  JavaTypeCache Cold;
  Cold.setDetailedStatsEnabled(true);
  const auto &ColdStats = Cold.Base.getStats();
  EXPECT_EQ(query(Second, &DT, F.back().getTerminator(), noNullEdge, Cold),
            getJavaType(Second, &DT, F.back().getTerminator(), noNullEdge));
  EXPECT_EQ(Cold.Base.getStats().Misses, 1U);
  EXPECT_EQ(Cold.Base.getStats().Hits, 1U);
  EXPECT_EQ(ColdStats.PriorQueryHits, 0U);
  EXPECT_EQ(ColdStats.CurrentQueryHits, 1U);
  EXPECT_EQ(ColdStats.NodesEvaluated, 3U);
}

TEST_F(CachedJavaTypeTest, DiagnosticCycleEdgesAreNotCountedAsCacheMisses) {
  auto M = parse(R"IR(
    define ptr addrspace(1) @test(
        ptr addrspace(1) "java-klass"="9" %a, i1 %again) {
    entry:
      br label %loop
    loop:
      %result = phi ptr addrspace(1) [ %a, %entry ], [ %result, %loop ]
      br i1 %again, label %loop, label %exit
    exit:
      ret ptr addrspace(1) %result
    }
  )IR");
  ASSERT_NE(M, nullptr);
  Value *V = returnedValue(*M->getFunction("test"));
  JavaTypeCache Cache;

  Cache.setDetailedStatsEnabled(true);
  const auto &D = Cache.Base.getStats();
  EXPECT_EQ(query(V, nullptr, nullptr, noNullEdge, Cache), fresh(V));
  EXPECT_EQ(D.InputEdgesVisited, D.InputHits + D.InputMisses + D.OpenNodeEdges);
  EXPECT_EQ(D.NodesEvaluated, 2U);
  EXPECT_EQ(D.InputMisses, 1U);
  EXPECT_EQ(D.OpenNodeEdges, 1U);
  EXPECT_EQ(D.CyclicSCCs, 1U);
  EXPECT_GE(D.RefinementSteps, 1U);
  EXPECT_EQ(D.PriorQueryHits, 0U);

  EXPECT_EQ(query(V, nullptr, nullptr, noNullEdge, Cache), fresh(V));
  EXPECT_EQ(Cache.Base.getStats().Hits, 1U);
  EXPECT_EQ(D.PriorQueryHits, 1U);
  EXPECT_EQ(D.NodesEvaluated, 0U);
  EXPECT_EQ(D.CyclicSCCs, 0U);
  EXPECT_EQ(D.RefinementSteps, 0U);
}

TEST_F(CachedJavaTypeTest, UnknownIsAReusableCompletedResult) {
  auto M = parse(R"IR(
    define ptr addrspace(1) @test(ptr addrspace(1) %a, i1 %pick) {
      %result = select i1 %pick, ptr addrspace(1) %a,
                                ptr addrspace(1) null
      ret ptr addrspace(1) %result
    }
  )IR");
  ASSERT_NE(M, nullptr);
  Value *V = returnedValue(*M->getFunction("test"));
  JavaTypeCache Cache;

  Cache.setDetailedStatsEnabled(true);
  const auto &D = Cache.Base.getStats();
  EXPECT_TRUE(query(V, Cache).isUnknown());
  EXPECT_TRUE(query(V, nullptr, nullptr, noNullEdge, Cache).isUnknown());
  EXPECT_EQ(Cache.Base.getStats().Hits, 1U);
  EXPECT_EQ(D.PriorQueryHits, 1U);
  EXPECT_EQ(D.NodesEvaluated, 0U);
}

TEST_F(CachedJavaTypeTest, OversizedInvalidationFallsBackToClear) {
  auto M = parse(R"IR(
    define ptr addrspace(1) @test(
        ptr addrspace(1) "java-klass"="9" "java-klass-exact" %a,
        i32 %n) {
      ret ptr addrspace(1) %a
    }
  )IR");
  ASSERT_NE(M, nullptr);
  Function &F = *M->getFunction("test");
  Instruction *Return = F.front().getTerminator();
  Value *Previous = F.getArg(1);
  for (unsigned I = 0; I < 4100; ++I)
    Previous = BinaryOperator::CreateAdd(
        Previous, ConstantInt::get(Type::getInt32Ty(Context), 1), "",
        Return->getIterator());
  JavaTypeCache Cache;

  EXPECT_EQ(query(F.getArg(0), Cache), JavaType(9, true));
  auto Invalidated = Cache.invalidate({F.getArg(1)});
  EXPECT_TRUE(Invalidated.FullClear);
  EXPECT_EQ(Invalidated.BaseRemoved, 1U);
  EXPECT_EQ(Cache.baseSize(), 0U);
  EXPECT_EQ(query(F.getArg(0), Cache), fresh(F.getArg(0)));
}

static BasicBlock *findFactsTestBlock(Function &F, StringRef Name) {
  for (BasicBlock &BB : F)
    if (BB.getName() == Name)
      return &BB;
  llvm_unreachable("missing facts test block");
}

using FactsCacheMode = JavaTypeFactsCache::Mode;

TEST_F(CachedJavaTypeTest, FactsEdgeModesReuseSharedEdgesAndSeparateValues) {
  auto M = parse(R"IR(
    declare i1 @jeandle.check_instanceof(ptr, ptr nonnull)
    define ptr @test(ptr %obj, ptr %other) {
    entry:
      %check = call i1 @jeandle.check_instanceof(
          ptr inttoptr(i64 9 to ptr), ptr %obj)
      br i1 %check, label %a, label %reject
    a:
      br label %b
    b:
      br label %c
    c:
      ret ptr %obj
    reject:
      ret ptr null
    }
  )IR");
  ASSERT_NE(M, nullptr);
  Function &F = *M->getFunction("test");
  DominatorTree DT(F);
  Instruction *AtB = findFactsTestBlock(F, "b")->getTerminator();
  Instruction *AtC = findFactsTestBlock(F, "c")->getTerminator();
  for (FactsCacheMode Mode :
       {FactsCacheMode::GuardOnly, FactsCacheMode::StableOracleEpoch}) {
    SCOPED_TRACE(Mode == FactsCacheMode::GuardOnly ? "guard" : "stable");
    JavaTypeCache Base(F, Mode);
    auto &Facts = Base.Facts;
    AssumptionCache AC(F);
    LazyValueInfo LVI(&AC, &M->getDataLayout());
    unsigned ActualCalls = 0, ReferenceCalls = 0;
    auto Oracle = [&](Value *V, BasicBlock *From, BasicBlock *To) {
      ++ActualCalls;
      return LVINullEdgeOracle{LVI}(V, From, To);
    };
    auto Compare = [&](Value *V, Instruction *At) {
      // Isolate the persistent edge layer from independent Base reuse.
      Base.Base.clear();

      JavaType Actual = query(V, &DT, At, Oracle, Base);
      AssumptionCache ReferenceAC(F);
      LazyValueInfo ReferenceLVI(&ReferenceAC, &M->getDataLayout());
      auto ReferenceOracle = [&](Value *X, BasicBlock *From, BasicBlock *To) {
        ++ReferenceCalls;
        return LVINullEdgeOracle{ReferenceLVI}(X, From, To);
      };
      EXPECT_EQ(Actual, getJavaType(V, &DT, At, ReferenceOracle));
      return Actual;
    };
    EXPECT_EQ(Compare(F.getArg(0), AtB), JavaType(9, false));
    EXPECT_EQ(ActualCalls, 2U);
    EXPECT_EQ(Compare(F.getArg(0), AtC), JavaType(9, false));
    EXPECT_EQ(ActualCalls, Mode == FactsCacheMode::GuardOnly ? 5U : 3U);
    EXPECT_EQ(Compare(F.getArg(0), AtC), JavaType(9, false));
    EXPECT_EQ(ActualCalls, Mode == FactsCacheMode::GuardOnly ? 8U : 3U);
    EXPECT_EQ(ReferenceCalls, 8U);
    EXPECT_EQ(Facts.getStats().GuardHits, 5U);

    // Same edges but a different raw Value must not inherit obj's guard.
    EXPECT_TRUE(Compare(F.getArg(1), AtC).isUnknown());
    EXPECT_EQ(ActualCalls, Mode == FactsCacheMode::GuardOnly ? 11U : 6U);
    EXPECT_EQ(ReferenceCalls, 11U);
    EXPECT_EQ(Facts.guardSize(), 6U);
    EXPECT_EQ(Facts.nullSize(), Mode == FactsCacheMode::GuardOnly ? 0U : 6U);
    EXPECT_EQ(Facts.getStats().NullRequests, 11U);
    EXPECT_EQ(Facts.getStats().NullHits,
              Mode == FactsCacheMode::GuardOnly ? 0U : 5U);
    EXPECT_EQ(Facts.getStats().NullComputed, ActualCalls);
    EXPECT_EQ(Facts.getStats().GuardRequests, 11U);
    EXPECT_EQ(Facts.getStats().GuardComputed, 6U);
    EXPECT_EQ(Facts.getStats().GuardBypasses, 0U);
    Facts.clear();
    EXPECT_EQ(Facts.guardSize(), 0U);
    EXPECT_EQ(Facts.nullSize(), 0U);
    EXPECT_EQ(Facts.getStats().GuardHits, 5U);
    Facts.resetStats();
    EXPECT_EQ(Facts.getStats().GuardRequests, 0U);
    EXPECT_EQ(Facts.getStats().NullRequests, 0U);
  }
}

TEST_F(CachedJavaTypeTest, FactsEdgesPreserveBudgetPhiCyclesAndSwitchResults) {
  auto M = parse(R"IR(
    declare i1 @jeandle.check_instanceof(ptr, ptr nonnull)
    define ptr @chain(ptr %obj) {
    entry:
      %check = call i1 @jeandle.check_instanceof(
          ptr inttoptr(i64 9 to ptr), ptr %obj)
      br i1 %check, label %a, label %reject
    a:
      br label %b
    b:
      br label %exit
    exit:
      ret ptr %obj
    reject:
      ret ptr null
    }
    define ptr @cycle(ptr "java-klass"="9" %left,
                      ptr "java-klass"="22" %right, i1 %again) {
    entry:
      br label %loop
    loop:
      %a = phi ptr [ %left, %entry ], [ %b, %loop ]
      %b = phi ptr [ %right, %entry ], [ %a, %loop ]
      br i1 %again, label %loop, label %exit
    exit:
      ret ptr %b
    }
    define ptr @irreducible(ptr %obj, i1 %pick, i1 %again) {
    entry:
      br i1 %pick, label %a, label %b
    a:
      %check = call i1 @jeandle.check_instanceof(
          ptr inttoptr(i64 9 to ptr), ptr %obj)
      br i1 %check, label %b, label %exit
    b:
      br i1 %again, label %a, label %exit
    exit:
      ret ptr %obj
    }
    define ptr @switchguard(ptr %obj) {
    entry:
      %check = call i1 @jeandle.check_instanceof(
          ptr inttoptr(i64 9 to ptr), ptr %obj)
      %wide = zext i1 %check to i32
      switch i32 %wide, label %reject [ i32 1, label %good
                                        i32 0, label %reject ]
    good:
      br label %exit
    reject:
      ret ptr null
    exit:
      ret ptr %obj
    }
  )IR");
  ASSERT_NE(M, nullptr);
  auto *Option =
      cl::getRegisteredOptions().lookup("jeandle-max-facts-join-blocks");
  ASSERT_NE(Option, nullptr);
  auto &Budget = *static_cast<cl::opt<unsigned> *>(Option);
  unsigned SavedBudget = Budget;
  auto RestoreBudget = make_scope_exit([&] { Budget = SavedBudget; });
  for (StringRef Name : {"chain", "cycle", "irreducible", "switchguard"}) {
    SCOPED_TRACE(Name.str());
    Function &F = *M->getFunction(Name);
    DominatorTree DT(F);
    if (Name == "irreducible") {
      EXPECT_FALSE(
          DT.dominates(findFactsTestBlock(F, "a"), findFactsTestBlock(F, "b")));
      EXPECT_FALSE(
          DT.dominates(findFactsTestBlock(F, "b"), findFactsTestBlock(F, "a")));
    }
    SmallVector<Value *, 3> Values{F.getArg(0)};
    if (Name == "cycle") {
      Values.push_back(findBaseTestInstruction(F, "a"));
      Values.push_back(findBaseTestInstruction(F, "b"));
    }
    for (FactsCacheMode Mode :
         {FactsCacheMode::GuardOnly, FactsCacheMode::StableOracleEpoch}) {
      SCOPED_TRACE(Mode == FactsCacheMode::GuardOnly ? "guard" : "stable");
      JavaTypeCache Base(F, Mode);
      auto &Facts = Base.Facts;
      // Complete warm entries must not evade a later query's budget or its
      // PHI/irreducible-cycle traversal decisions.
      for (unsigned Limit : {128U, 1U, 2U, 0U, 128U, 1U}) {
        SCOPED_TRACE(Limit);
        Budget = Limit;
        for (Value *V : Values) {
          Base.Base.clear();

          Instruction *At = findFactsTestBlock(F, "exit")->getTerminator();
          JavaType Actual = query(V, &DT, At, noNullEdge, Base);
          EXPECT_EQ(Actual, getJavaType(V, &DT, At, noNullEdge));
          if (Name == "chain")
            EXPECT_EQ(Actual.Klass, Limit >= 3 ? 9U : 0U);
        }
      }
      EXPECT_GT(Facts.getStats().GuardHits, 0U);
      if (Mode == FactsCacheMode::StableOracleEpoch)
        EXPECT_GT(Facts.getStats().NullHits, 0U);
      else
        EXPECT_EQ(Facts.nullSize(), 0U);
    }
  }
}

TEST_F(CachedJavaTypeTest,
       FactsDefaultFollowsOracleChangesAndStableModeClears) {
  auto M = parse(R"IR(
    declare i1 @jeandle.check_instanceof(ptr, ptr nonnull)
    define ptr @test(ptr %arg, i1 %choose_null) {
    entry:
      %obj = select i1 %choose_null, ptr null, ptr %arg
      br i1 %choose_null, label %nullbb, label %checkbb
    nullbb:
      br label %join
    checkbb:
      %check = call i1 @jeandle.check_instanceof(
          ptr inttoptr(i64 9 to ptr), ptr %obj)
      br i1 %check, label %good, label %reject
    good:
      br label %join
    join:
      ret ptr %obj
    reject:
      ret ptr null
    }
  )IR");
  ASSERT_NE(M, nullptr);
  Function &F = *M->getFunction("test");
  DominatorTree DT(F);
  Value *Obj = findBaseTestInstruction(F, "obj");
  BasicBlock *NullBB = findFactsTestBlock(F, "nullbb");
  BasicBlock *Join = findFactsTestBlock(F, "join");
  bool Enhanced = false;
  auto Oracle = [&](Value *V, BasicBlock *From, BasicBlock *To) {
    // Both versions are sound. Only the enhanced version proves the null arm.
    return Enhanced && V == Obj && From == NullBB && To == Join;
  };
  auto Compare = [&](JavaTypeCache &Base) {
    Base.Base.clear();

    JavaType Actual = query(Obj, &DT, Join->getTerminator(), Oracle, Base);
    EXPECT_EQ(Actual, getJavaType(Obj, &DT, Join->getTerminator(), Oracle));
    return Actual;
  };
  // The default must follow changes in a sound oracle without an epoch reset.
  JavaTypeCache DefaultCache(F);
  auto &DefaultFacts = DefaultCache.Facts;
  EXPECT_TRUE(Compare(DefaultCache).isUnknown());
  Enhanced = true;
  EXPECT_EQ(Compare(DefaultCache), JavaType(9, false));
  EXPECT_EQ(DefaultFacts.nullSize(), 0U);
  EXPECT_GT(DefaultFacts.getStats().GuardHits, 0U);

  // Explicit bool memoization instead requires a new epoch when knowledge
  // changes, even though every instruction and CFG edge is unchanged.
  Enhanced = false;
  JavaTypeCache StableCache(F, FactsCacheMode::StableOracleEpoch);
  auto &StableFacts = StableCache.Facts;
  EXPECT_TRUE(Compare(StableCache).isUnknown());
  EXPECT_GT(StableFacts.nullSize(), 0U);
  StableFacts.clear();
  Enhanced = true;
  EXPECT_EQ(Compare(StableCache), JavaType(9, false));
}

TEST_F(CachedJavaTypeTest, FactsClearRefreshesGuardsAndAddedCFGEdges) {
  for (FactsCacheMode Mode :
       {FactsCacheMode::GuardOnly, FactsCacheMode::StableOracleEpoch}) {
    SCOPED_TRACE(Mode == FactsCacheMode::GuardOnly ? "guard" : "stable");
    auto M = parse(R"IR(
      declare i1 @jeandle.check_instanceof(ptr, ptr nonnull)
      define ptr @test(ptr %obj) {
      entry:
        %check = call i1 @jeandle.check_instanceof(
            ptr inttoptr(i64 9 to ptr), ptr %obj)
        br i1 %check, label %good, label %reject
      good:
        br label %exit
      exit:
        ret ptr %obj
      reject:
        ret ptr null
      }
    )IR");
    ASSERT_NE(M, nullptr);
    Function &F = *M->getFunction("test");
    DominatorTree DT(F);
    JavaTypeCache Base(F, Mode);
    auto &Facts = Base.Facts;
    auto Compare = [&] {
      Base.Base.clear();

      Instruction *At = findFactsTestBlock(F, "exit")->getTerminator();
      JavaType Actual = query(F.getArg(0), &DT, At, noNullEdge, Base);
      EXPECT_EQ(Actual, getJavaType(F.getArg(0), &DT, At, noNullEdge));
      return Actual;
    };
    EXPECT_EQ(Compare(), JavaType(9, false));
    Facts.clear();
    auto *Check = cast<CallInst>(findBaseTestInstruction(F, "check"));
    Check->setArgOperand(0, ConstantExpr::getIntToPtr(
                                ConstantInt::get(Type::getInt64Ty(Context), 22),
                                PointerType::get(Context, 0)));
    EXPECT_EQ(Compare(), JavaType(22, false));
    EXPECT_EQ(Compare(), JavaType(22, false));

    // A new incoming path bypasses the successful check. All edge entries,
    // including negative facts, must be rebuilt against the updated CFG/DT.
    Facts.clear();
    Instruction *Old = findFactsTestBlock(F, "reject")->getTerminator();
    BranchInst::Create(findFactsTestBlock(F, "exit"), Old->getIterator());
    Old->eraseFromParent();
    DT.recalculate(F);
    EXPECT_FALSE(verifyModule(*M, &errs()));
    EXPECT_TRUE(Compare().isUnknown());
    EXPECT_TRUE(Compare().isUnknown());
  }
}

TEST_F(CachedJavaTypeTest, FactsClearBeforeRAUWAndDeletionDropsRawKeys) {
  for (FactsCacheMode Mode :
       {FactsCacheMode::GuardOnly, FactsCacheMode::StableOracleEpoch}) {
    SCOPED_TRACE(Mode == FactsCacheMode::GuardOnly ? "guard" : "stable");
    auto M = parse(R"IR(
      declare i1 @jeandle.check_instanceof(ptr, ptr nonnull)
      define ptr @test(ptr %obj, ptr %replacement) {
      entry:
        %old = select i1 true, ptr %obj, ptr %obj
        %check = call i1 @jeandle.check_instanceof(
            ptr inttoptr(i64 9 to ptr), ptr %old)
        br i1 %check, label %good, label %reject
      good:
        ret ptr %old
      reject:
        ret ptr null
      }
    )IR");
    ASSERT_NE(M, nullptr);
    Function &F = *M->getFunction("test");
    DominatorTree DT(F);
    JavaTypeCache Base(F, Mode);
    auto &Facts = Base.Facts;
    Instruction *At = findFactsTestBlock(F, "good")->getTerminator();
    auto Compare = [&](Value *V) {
      JavaType Actual = query(V, &DT, At, noNullEdge, Base);
      EXPECT_EQ(Actual, getJavaType(V, &DT, At, noNullEdge));
      return Actual;
    };
    Instruction *Old = findBaseTestInstruction(F, "old");
    EXPECT_EQ(Compare(Old), JavaType(9, false));
    EXPECT_GT(Facts.guardSize(), 0U);
    Facts.clear();
    Base.invalidate({Old});
    EXPECT_EQ(Facts.guardSize(), 0U);
    EXPECT_EQ(Facts.nullSize(), 0U);
    Old->replaceAllUsesWith(F.getArg(1));
    Old->eraseFromParent();
    EXPECT_FALSE(verifyModule(*M, &errs()));
    EXPECT_TRUE(Compare(F.getArg(0)).isUnknown());
    EXPECT_EQ(Compare(F.getArg(1)), JavaType(9, false));
  }
}

TEST_F(CachedJavaTypeTest, FactsClearRefreshesMovedDefinitionContext) {
  for (FactsCacheMode Mode :
       {FactsCacheMode::GuardOnly, FactsCacheMode::StableOracleEpoch}) {
    SCOPED_TRACE(Mode == FactsCacheMode::GuardOnly ? "guard" : "stable");
    auto M = parse(R"IR(
      declare i1 @jeandle.check_instanceof(ptr, ptr nonnull)
      define ptr @test(ptr %obj) {
      entry:
        %value = select i1 true, ptr %obj, ptr %obj
        %check = call i1 @jeandle.check_instanceof(
            ptr inttoptr(i64 9 to ptr), ptr %obj)
        br i1 %check, label %good, label %reject
      good:
        br label %exit
      exit:
        ret ptr %value
      reject:
        ret ptr null
      }
    )IR");
    ASSERT_NE(M, nullptr);
    Function &F = *M->getFunction("test");
    DominatorTree DT(F);
    JavaTypeCache Base(F, Mode);
    auto &Facts = Base.Facts;
    Instruction *V = findBaseTestInstruction(F, "value");
    auto Compare = [&] {
      Instruction *At = findFactsTestBlock(F, "exit")->getTerminator();
      JavaType Actual = query(V, &DT, At, noNullEdge, Base);
      EXPECT_EQ(Actual, getJavaType(V, &DT, At, noNullEdge));
      return Actual;
    };
    Compare();
    Facts.clear();
    // Moving an instruction leaves its Base inputs intact, but changes the
    // definition-point path facts used by the value dimension.
    V->moveBefore(
        findFactsTestBlock(F, "good")->getTerminator()->getIterator());
    DT.recalculate(F);
    EXPECT_FALSE(verifyModule(*M, &errs()));
    EXPECT_EQ(Compare(), JavaType(9, false));
    EXPECT_EQ(Compare(), JavaType(9, false));
  }
}

TEST_F(CachedJavaTypeTest, FactsNullMemoRetainsRawPhiIncomingIdentity) {
  auto M = parse(R"IR(
    define ptr @test(ptr "java-klass"="9" %typed, i1 %pick) {
    entry:
      %first = getelementptr i8, ptr null, i64 0
      %second = getelementptr i8, ptr null, i64 0
      br i1 %pick, label %nullpath, label %typedpath
    nullpath:
      br label %join
    typedpath:
      br label %join
    join:
      %p = phi ptr [ %first, %nullpath ], [ %typed, %typedpath ]
      %q = phi ptr [ %second, %nullpath ], [ %typed, %typedpath ]
      ret ptr %q
    }
  )IR");
  ASSERT_NE(M, nullptr);
  Function &F = *M->getFunction("test");
  DominatorTree DT(F);
  Value *First = findBaseTestInstruction(F, "first");
  Value *Second = findBaseTestInstruction(F, "second");
  ASSERT_EQ(First->stripPointerCasts(), Second->stripPointerCasts());
  BasicBlock *From = findFactsTestBlock(F, "nullpath");
  BasicBlock *To = findFactsTestBlock(F, "join");
  unsigned FirstCalls = 0, SecondCalls = 0;
  auto StableOracle = [&](Value *V, BasicBlock *A, BasicBlock *B) {
    // The first wrapper has a positive proof; the second returns unknown.
    // Canonicalizing the memo key would incorrectly reuse one response for
    // the other, even though this oracle is stable and sound for both.
    return V == First && A == From && B == To;
  };
  auto CountedOracle = [&](Value *V, BasicBlock *A, BasicBlock *B) {
    if (A == From && B == To) {
      FirstCalls += V == First;
      SecondCalls += V == Second;
    }
    return StableOracle(V, A, B);
  };
  JavaTypeCache Base(F, FactsCacheMode::StableOracleEpoch);
  for (StringRef Name : {"p", "q", "p", "q"}) {
    Value *V = findBaseTestInstruction(F, Name);
    Base.Base.clear();

    EXPECT_EQ(query(V, &DT, To->getTerminator(), CountedOracle, Base),
              getJavaType(V, &DT, To->getTerminator(), StableOracle));
  }
  EXPECT_EQ(FirstCalls, 1U);
  EXPECT_EQ(SecondCalls, 1U);
}

TEST_F(CachedJavaTypeTest, DefinedProofsInvalidateEvenWhenBaseIsEmpty) {
  auto M = parse(R"IR(
    define ptr @test(ptr noundef "java-klass"="9" %a,
                     ptr noundef "java-klass"="9" %b,
                     ptr noundef "java-klass"="22" %unrelated,
                     i32 noundef %n) {
      %sum = add i32 %n, 1
      %condition = icmp eq i32 %sum, 0
      %selected = select i1 %condition, ptr %a, ptr %b
      %first = freeze ptr %selected
      %second = freeze ptr %selected
      %independent = freeze ptr %unrelated
      ret ptr %second
    }
  )IR");
  ASSERT_NE(M, nullptr);
  Function &F = *M->getFunction("test");
  Value *First = findBaseTestInstruction(F, "first");
  Value *Second = findBaseTestInstruction(F, "second");
  Value *Independent = findBaseTestInstruction(F, "independent");
  auto *Sum = cast<BinaryOperator>(findBaseTestInstruction(F, "sum"));
  JavaTypeCache Cache(F);
  Cache.setStatsEnabled(true);
  auto Query = [&](Value *V) {
    JavaType Actual = getCachedJavaType(V, nullptr, nullptr, noNullEdge, Cache);
    EXPECT_EQ(Actual, fresh(V));
    return Actual;
  };

  EXPECT_EQ(Query(First), JavaType(9, false));
  EXPECT_GT(Cache.Defined.getStats().NodesEvaluated, 0U);
  Cache.Base.clear();
  Cache.Defined.resetStats();
  EXPECT_EQ(Query(Second), JavaType(9, false));
  EXPECT_GT(Cache.Defined.getStats().Hits, 0U);
  EXPECT_EQ(Cache.Defined.getStats().NodesEvaluated, 0U);
  EXPECT_EQ(Query(Independent), JavaType(22, false));

  // The aggregate must traverse Changed even if only Defined has entries.
  Cache.Base.clear();
  ASSERT_EQ(Cache.baseSize(), 0U);
  ASSERT_GT(Cache.definedSize(), 0U);
  auto Removed = Cache.invalidate({Sum});
  EXPECT_FALSE(Removed.FullClear);
  EXPECT_EQ(Removed.BaseRemoved, 0U);
  EXPECT_GT(Removed.DefinedRemoved, 0U);
  EXPECT_GT(Cache.definedSize(), 0U);
  Sum->setHasNoSignedWrap(true);
  EXPECT_TRUE(Query(Second).isUnknown());

  Cache.Base.clear();
  Cache.Defined.resetStats();
  EXPECT_EQ(Query(Independent), JavaType(22, false));
  EXPECT_GT(Cache.Defined.getStats().Hits, 0U);
  EXPECT_EQ(Cache.Defined.getStats().NodesEvaluated, 0U);
}

TEST_F(CachedJavaTypeTest, DefinedNegativeProofRefreshesAfterAttributeEdit) {
  auto M = parse(R"IR(
    define ptr @test(ptr "java-klass"="9" %obj) {
      %first = freeze ptr %obj
      %second = freeze ptr %obj
      ret ptr %second
    }
  )IR");
  ASSERT_NE(M, nullptr);
  Function &F = *M->getFunction("test");
  JavaTypeCache Cache(F);
  Cache.setStatsEnabled(true);
  Value *First = findBaseTestInstruction(F, "first");
  Value *Second = findBaseTestInstruction(F, "second");
  EXPECT_TRUE(getCachedJavaType(First, nullptr, nullptr, noNullEdge, Cache)
                  .isUnknown());
  Cache.Defined.resetStats();
  EXPECT_TRUE(getCachedJavaType(Second, nullptr, nullptr, noNullEdge, Cache)
                  .isUnknown());
  EXPECT_GT(Cache.Defined.getStats().Hits, 0U);
  EXPECT_EQ(Cache.Defined.getStats().NodesEvaluated, 0U);

  auto Removed = Cache.invalidate({F.getArg(0)});
  EXPECT_GT(Removed.DefinedRemoved, 0U);
  F.addParamAttr(0, Attribute::NoUndef);
  EXPECT_EQ(getCachedJavaType(Second, nullptr, nullptr, noNullEdge, Cache),
            JavaType(9, false));
  EXPECT_EQ(getCachedJavaType(First, nullptr, nullptr, noNullEdge, Cache),
            fresh(First));
}

TEST_F(CachedJavaTypeTest,
       FinalReuseIgnoresBudgetAndOnlyPublishesTopLevelResults) {
  auto M = parse(R"IR(
    declare i1 @jeandle.check_instanceof(ptr, ptr nonnull)
    define ptr @test(ptr %obj) {
    entry:
      %check = call i1 @jeandle.check_instanceof(
          ptr inttoptr(i64 9 to ptr), ptr %obj)
      br i1 %check, label %accepted, label %rejected
    accepted:
      br label %query
    query:
      %unused = ptrtoint ptr %obj to i64
      ret ptr %obj
    rejected:
      ret ptr null
    }
    define ptr @cycle(ptr "java-klass"="9" %a,
                      ptr "java-klass"="22" %b, i1 %again) {
    entry:
      br label %loop
    loop:
      %left = phi ptr [ %a, %entry ], [ %right, %loop ]
      %right = phi ptr [ %b, %entry ], [ %left, %loop ]
      br i1 %again, label %loop, label %exit
    exit:
      ret ptr %left
    }
  )IR");
  ASSERT_NE(M, nullptr);
  auto *Option =
      cl::getRegisteredOptions().lookup("jeandle-max-facts-join-blocks");
  ASSERT_NE(Option, nullptr);
  auto &Budget = *static_cast<cl::opt<unsigned> *>(Option);
  unsigned Saved = Budget;
  auto Restore = make_scope_exit([&] { Budget = Saved; });
  Function &F = *M->getFunction("test");
  DominatorTree DT(F);
  BasicBlock *At = findFactsTestBlock(F, "query");
  for (unsigned InitialLimit : {1U, 128U}) {
    SCOPED_TRACE(InitialLimit);
    Budget = InitialLimit;
    JavaTypeCache Cache(F, FactsCacheMode::StableOracleEpoch);
    Cache.setStatsEnabled(true);
    unsigned OracleCalls = 0;
    auto Oracle = [&](Value *, BasicBlock *, BasicBlock *) {
      ++OracleCalls;
      return false;
    };
    JavaType Expected =
        getJavaType(F.getArg(0), &DT, At->getTerminator(), noNullEdge);
    if (InitialLimit == 1)
      EXPECT_TRUE(Expected.isUnknown());
    else
      EXPECT_EQ(Expected, JavaType(9, false));
    EXPECT_EQ(
        getCachedJavaType(F.getArg(0), &DT, At->getTerminator(), Oracle, Cache),
        Expected);
    unsigned CallsAfterMiss = OracleCalls;
    for (unsigned Limit : {0U, 1U, 128U}) {
      SCOPED_TRACE(Limit);
      Budget = Limit;
      uint64_t Hits = Cache.Final.getStats().Hits;
      uint64_t BaseMisses = Cache.Base.getStats().Misses;
      // Solving budgets do not invalidate an answer. Both precise and
      // conservative answers remain reusable without repeating oracle work.
      EXPECT_EQ(getCachedJavaType(F.getArg(0), &DT, At->getTerminator(), Oracle,
                                  Cache),
                Expected);
      // Different instructions in one block share the same Final entry.
      EXPECT_EQ(
          getCachedJavaType(F.getArg(0), &DT, &At->front(), Oracle, Cache),
          Expected);
      EXPECT_EQ(Cache.Final.getStats().Hits, Hits + 2);
      EXPECT_EQ(Cache.Base.getStats().Misses, BaseMisses);
      EXPECT_EQ(OracleCalls, CallsAfterMiss);
      EXPECT_EQ(Cache.finalTypesSize(), 1U);
    }
  }

  Budget = 128;
  Function &Cycle = *M->getFunction("cycle");
  DominatorTree CycleDT(Cycle);
  BasicBlock *Exit = findFactsTestBlock(Cycle, "exit");
  for (bool Reverse : {false, true}) {
    SCOPED_TRACE(Reverse);
    JavaTypeCache CyclicCache(Cycle, FactsCacheMode::StableOracleEpoch);
    CyclicCache.setStatsEnabled(true);
    Value *Left = findBaseTestInstruction(Cycle, "left");
    Value *Right = findBaseTestInstruction(Cycle, "right");
    for (Value *V : {Reverse ? Right : Left, Reverse ? Left : Right}) {
      EXPECT_EQ(getCachedJavaType(V, &CycleDT, Exit->getTerminator(),
                                  noNullEdge, CyclicCache),
                getJavaType(V, &CycleDT, Exit->getTerminator(), noNullEdge));
    }
    // Internal value/PHI recursion did not consume or publish Final entries.
    EXPECT_EQ(CyclicCache.finalTypesSize(), 2U);
    EXPECT_EQ(CyclicCache.Final.getStats().Hits, 0U);
  }
}

TEST_F(CachedJavaTypeTest,
       FinalInvalidationClearsAllContextsWithWarmSubcaches) {
  auto M = parse(R"IR(
    declare i1 @jeandle.check_instanceof(ptr, ptr nonnull)
    define void @test(ptr noundef %obj, i1 %choose) {
    entry:
      %wrapped = freeze ptr %obj
      br i1 %choose, label %left, label %right
    left:
      %leftcheck = call i1 @jeandle.check_instanceof(
          ptr inttoptr(i64 9 to ptr), ptr %wrapped)
      br i1 %leftcheck, label %leftgood, label %leftbad
    leftgood:
      ret void
    leftbad:
      ret void
    right:
      %rightcheck = call i1 @jeandle.check_instanceof(
          ptr inttoptr(i64 22 to ptr), ptr %wrapped)
      br i1 %rightcheck, label %rightgood, label %rightbad
    rightgood:
      ret void
    rightbad:
      ret void
    }
  )IR");
  ASSERT_NE(M, nullptr);
  Function &F = *M->getFunction("test");
  DominatorTree DT(F);
  Value *V = findBaseTestInstruction(F, "wrapped");
  Instruction *Left = findFactsTestBlock(F, "leftgood")->getTerminator();
  Instruction *Right = findFactsTestBlock(F, "rightgood")->getTerminator();
  JavaTypeCache Cache(F, FactsCacheMode::StableOracleEpoch);
  Cache.setStatsEnabled(true);
  auto Query = [&](Instruction *At) {
    JavaType Actual = getCachedJavaType(V, &DT, At, noNullEdge, Cache);
    EXPECT_EQ(Actual, getJavaType(V, &DT, At, noNullEdge));
    return Actual;
  };
  Cache.setFinalEnabled(false);
  EXPECT_EQ(Query(Left), JavaType(9, false));
  EXPECT_EQ(Query(Right), JavaType(22, false));
  EXPECT_GT(Cache.baseSize(), 0U);
  EXPECT_GT(Cache.definedSize(), 0U);
  EXPECT_GT(Cache.pathFactsSize(), 0U);

  Cache.setFinalEnabled(true);
  EXPECT_EQ(Query(Left), JavaType(9, false));
  EXPECT_EQ(Query(Right), JavaType(22, false));
  ASSERT_EQ(Cache.finalTypesSize(), 2U);
  EXPECT_GT(Cache.Facts.getStats().PathHits, 0U);
  auto *Check = cast<CallInst>(findBaseTestInstruction(F, "leftcheck"));
  auto Removed = Cache.invalidate({Check});
  EXPECT_FALSE(Removed.FullClear);
  EXPECT_EQ(Removed.FinalRemoved, 2U);
  EXPECT_EQ(Removed.FinalTypesSlotsScanned, 0U);
  EXPECT_EQ(Cache.finalTypesSize(), 0U);
  EXPECT_EQ(Cache.pathFactsSize(), 0U);
  Check->setArgOperand(0, ConstantExpr::getIntToPtr(
                              ConstantInt::get(Type::getInt64Ty(Context), 22),
                              PointerType::get(Context, 0)));

  uint64_t Hits = Cache.Final.getStats().Hits;
  uint64_t Misses = Cache.Final.getStats().Misses;
  // A modification clears every Final context, including the unchanged arm.
  EXPECT_EQ(Query(Right), JavaType(22, false));
  EXPECT_EQ(Query(Left), JavaType(22, false));
  EXPECT_EQ(Cache.Final.getStats().Hits, Hits);
  EXPECT_EQ(Cache.Final.getStats().Misses, Misses + 2);
  EXPECT_EQ(Query(Right), JavaType(22, false));
  EXPECT_EQ(Cache.Final.getStats().Hits, Hits + 1);
  EXPECT_FALSE(verifyModule(*M, &errs()));
}

TEST_F(CachedJavaTypeTest, FinalClearsForUnrelatedEditsAndCFGChanges) {
  auto M = parse(R"IR(
    define ptr @test(ptr noundef "java-klass"="9" %obj, i1 %choose, i32 %n) {
    entry:
      %sum = add i32 %n, 1
      %wrapped = freeze ptr %obj
      br i1 %choose, label %left, label %right
    left:
      ret ptr %wrapped
    right:
      ret ptr %wrapped
    }
  )IR");
  ASSERT_NE(M, nullptr);
  Function &F = *M->getFunction("test");
  DominatorTree DT(F);
  Instruction *Wrapped = findBaseTestInstruction(F, "wrapped");
  Instruction *At = findFactsTestBlock(F, "left")->getTerminator();
  auto *Sum = findBaseTestInstruction(F, "sum");
  auto *Branch = cast<BranchInst>(F.front().getTerminator());
  for (bool CFGChanged : {false, true}) {
    SCOPED_TRACE(CFGChanged);
    JavaTypeCache Cache(F, FactsCacheMode::StableOracleEpoch);
    Cache.setStatsEnabled(true);
    EXPECT_EQ(getCachedJavaType(Wrapped, &DT, At, noNullEdge, Cache),
              JavaType(9, false));
    ASSERT_GT(Cache.baseSize(), 0U);
    ASSERT_GT(Cache.definedSize(), 0U);
    ASSERT_EQ(Cache.finalTypesSize(), 1U);

    auto Removed = Cache.invalidate(
        {CFGChanged ? F.front().getTerminator() : Sum}, CFGChanged);
    EXPECT_EQ(Removed.FinalRemoved, 1U);
    EXPECT_EQ(Cache.finalTypesSize(), 0U);
    EXPECT_TRUE(Cache.Base.storage().contains(F.getArg(0)));
    EXPECT_TRUE(Cache.Defined.storage().contains(F.getArg(0)));
    if (CFGChanged) {
      Branch->swapSuccessors();
      DT.recalculate(F);
    } else {
      Sum->setOperand(1, ConstantInt::get(Type::getInt32Ty(Context), 2));
    }
    EXPECT_EQ(getCachedJavaType(Wrapped, &DT, At, noNullEdge, Cache),
              getJavaType(Wrapped, &DT, At, noNullEdge));
    EXPECT_EQ(Cache.Final.getStats().Hits, 0U);
    EXPECT_EQ(Cache.Final.getStats().Misses, 2U);
  }
  EXPECT_FALSE(verifyModule(*M, &errs()));
}

TEST_F(CachedJavaTypeTest, FinalClearsAfterExplicitOracleMaintenance) {
  auto M = parse(R"IR(
    declare i1 @jeandle.check_instanceof(ptr, ptr nonnull)
    define ptr @test(ptr %arg, i1 %choose_null) {
    entry:
      %obj = select i1 %choose_null, ptr null, ptr %arg
      br i1 %choose_null, label %nullbb, label %checkbb
    nullbb:
      br label %join
    checkbb:
      %check = call i1 @jeandle.check_instanceof(
          ptr inttoptr(i64 9 to ptr), ptr %obj)
      br i1 %check, label %good, label %reject
    good:
      br label %join
    join:
      ret ptr %obj
    reject:
      ret ptr null
    }
  )IR");
  ASSERT_NE(M, nullptr);
  Function &F = *M->getFunction("test");
  DominatorTree DT(F);
  Value *Obj = findBaseTestInstruction(F, "obj");
  BasicBlock *NullBB = findFactsTestBlock(F, "nullbb");
  BasicBlock *Join = findFactsTestBlock(F, "join");
  bool Enhanced = false;
  unsigned Calls = 0;
  auto Oracle = [&](Value *V, BasicBlock *From, BasicBlock *To) {
    ++Calls;
    return Enhanced && V == Obj && From == NullBB && To == Join;
  };
  // GuardOnly promises no oracle stability, so Final must not turn an
  // initially conservative answer into a permanently cached answer.
  JavaTypeCache Dynamic(F);
  Dynamic.setStatsEnabled(true);
  EXPECT_TRUE(
      getCachedJavaType(Obj, &DT, Join->getTerminator(), Oracle, Dynamic)
          .isUnknown());
  Enhanced = true;
  EXPECT_EQ(getCachedJavaType(Obj, &DT, Join->getTerminator(), Oracle, Dynamic),
            JavaType(9, false));
  EXPECT_EQ(Dynamic.finalTypesSize(), 0U);
  EXPECT_EQ(Dynamic.Final.getStats().Hits, 0U);
  Enhanced = false;
  Calls = 0;
  JavaTypeCache Cache(F, FactsCacheMode::StableOracleEpoch);
  Cache.setStatsEnabled(true);
  EXPECT_TRUE(getCachedJavaType(Obj, &DT, Join->getTerminator(), Oracle, Cache)
                  .isUnknown());
  unsigned ColdCalls = Calls;
  EXPECT_TRUE(getCachedJavaType(Obj, &DT, Join->getTerminator(), Oracle, Cache)
                  .isUnknown());
  EXPECT_EQ(Calls, ColdCalls);
  EXPECT_EQ(Cache.Final.getStats().Hits, 1U);

  Cache.notifyOracleChanged();
  Enhanced = true;
  EXPECT_EQ(Cache.finalTypesSize(), 0U);
  EXPECT_EQ(Cache.pathFactsSize(), 0U);
  JavaType Actual =
      getCachedJavaType(Obj, &DT, Join->getTerminator(), Oracle, Cache);
  EXPECT_EQ(Actual, getJavaType(Obj, &DT, Join->getTerminator(), Oracle));
  EXPECT_EQ(Actual, JavaType(9, false));
  EXPECT_EQ(Cache.Final.getStats().Misses, 2U);
  EXPECT_GT(Calls, ColdCalls);
  unsigned CallsAfterRefresh = Calls;
  EXPECT_EQ(getCachedJavaType(Obj, &DT, Join->getTerminator(), Oracle, Cache),
            Actual);
  EXPECT_EQ(Cache.Final.getStats().Hits, 2U);
  EXPECT_EQ(Calls, CallsAfterRefresh);
}

TEST_F(CachedJavaTypeTest,
       AnalysisInvalidationRefreshesNonSSAOracleDependency) {
  auto M = parse(R"IR(
    declare void @llvm.assume(i1)
    define ptr @test(ptr %obj, ptr "java-klass"="9" %typed, i1 %choose) {
    entry:
      %isnull = icmp eq ptr %obj, null
      call void @llvm.assume(i1 %isnull)
      br i1 %choose, label %nullpath, label %typedpath
    nullpath:
      br label %merge
    typedpath:
      br label %merge
    merge:
      %result = phi ptr [ %obj, %nullpath ], [ %typed, %typedpath ]
      ret ptr %result
    }
  )IR");
  ASSERT_NE(M, nullptr);
  auto *Option = cl::getRegisteredOptions().lookup("jeandle-java-type-stats");
  ASSERT_NE(Option, nullptr);
  auto &StatsOption = *static_cast<cl::opt<bool> *>(Option);
  bool Saved = StatsOption;
  auto Restore = make_scope_exit([&] { StatsOption = Saved; });
  StatsOption = true;

  Function &F = *M->getFunction("test");
  Value *V = returnedValue(F);
  Instruction *At = F.back().getTerminator();
  FunctionAnalysisManager FAM;
  PassBuilder PB;
  PB.registerFunctionAnalyses(FAM);
  auto &Analysis = FAM.getResult<JavaTypeAnalysis>(F);
  const auto &Stats = FAM.getResult<JavaTypeStatsAnalysis>(F).getStats();
  EXPECT_EQ(Analysis.getJavaType(V, At), JavaType(9, false));
  EXPECT_EQ(Analysis.getJavaType(V, At), JavaType(9, false));
  EXPECT_EQ(Stats.FinalHits, 1U);
  EXPECT_GT(Stats.CurrentBaseEntries, 0U);
  EXPECT_GT(Stats.CurrentPathFactsEntries, 0U);

  auto *Assume = cast<CallInst>(F.front().front().getNextNode());
  ASSERT_TRUE(Assume->use_empty());
  Analysis.invalidate(*Assume);
  EXPECT_GT(Stats.FinalRemoved, 0U);
  EXPECT_EQ(Stats.CurrentFinalTypeEntries, 0U);
  Assume->setArgOperand(0, ConstantInt::getTrue(Context));

  // Compare against independently constructed DT/AC/LVI, not warm analysis
  // objects. An assume is not in the result's ordinary SSA operand closure.
  DominatorTree FreshDT(F);
  AssumptionCache FreshAC(F);
  LazyValueInfo FreshLVI(&FreshAC, &M->getDataLayout());
  JavaType Expected = getJavaType(V, &FreshDT, At, LVINullEdgeOracle{FreshLVI});
  EXPECT_TRUE(Expected.isUnknown());
  EXPECT_EQ(Analysis.getJavaType(V, At), Expected);
  EXPECT_FALSE(verifyModule(*M, &errs()));
}

TEST_F(CachedJavaTypeTest,
       AnalysisMaintainsAllFourCachesBeforeRAUWAndDeletion) {
  auto M = parse(R"IR(
    declare i1 @jeandle.check_instanceof(ptr, ptr nonnull)
    define ptr @test(ptr noundef %obj) {
    entry:
      %wrapped = freeze ptr %obj
      %check = call i1 @jeandle.check_instanceof(
          ptr inttoptr(i64 9 to ptr), ptr %wrapped)
      br i1 %check, label %accepted, label %rejected
    accepted:
      br label %tail
    tail:
      ret ptr %wrapped
    rejected:
      ret ptr null
    }
  )IR");
  ASSERT_NE(M, nullptr);
  auto *Option = cl::getRegisteredOptions().lookup("jeandle-java-type-stats");
  ASSERT_NE(Option, nullptr);
  auto &StatsOption = *static_cast<cl::opt<bool> *>(Option);
  bool Saved = StatsOption;
  auto Restore = make_scope_exit([&] { StatsOption = Saved; });
  StatsOption = true;
  Function &F = *M->getFunction("test");
  Instruction *Wrapped = findBaseTestInstruction(F, "wrapped");
  Instruction *Accepted = findFactsTestBlock(F, "accepted")->getTerminator();
  Instruction *Tail = findFactsTestBlock(F, "tail")->getTerminator();
  FunctionAnalysisManager FAM;
  PassBuilder PB;
  PB.registerFunctionAnalyses(FAM);
  auto &Analysis = FAM.getResult<JavaTypeAnalysis>(F);
  const auto &Stats = FAM.getResult<JavaTypeStatsAnalysis>(F).getStats();
  EXPECT_EQ(Analysis.getJavaType(Wrapped, Accepted), JavaType(9, false));
  EXPECT_EQ(Analysis.getJavaType(Wrapped, Tail), JavaType(9, false));
  EXPECT_EQ(Analysis.getJavaType(Wrapped, Tail), JavaType(9, false));
  EXPECT_GT(Stats.BaseHits, 0U);
  EXPECT_GT(Stats.DefinedHits, 0U);
  EXPECT_GT(Stats.FactsHits, 0U);
  EXPECT_EQ(Stats.FinalHits, 1U);
  EXPECT_GT(Stats.CurrentDefinedEntries, 0U);
  EXPECT_EQ(Stats.CurrentFinalTypeEntries, 2U);

  Analysis.invalidate(*Wrapped);
  EXPECT_EQ(Stats.CurrentFinalTypeEntries, 0U);
  EXPECT_EQ(Stats.CurrentPathFactsEntries, 0U);
  Wrapped->replaceAllUsesWith(F.getArg(0));
  Wrapped->eraseFromParent();
  EXPECT_EQ(Analysis.getJavaType(F.getArg(0), Tail), JavaType(9, false));
  Analysis.invalidate(*F.getArg(0));
  EXPECT_EQ(Stats.CurrentDefinedEntries, 0U);
  F.removeParamAttr(0, Attribute::NoUndef);
  EXPECT_EQ(Analysis.getJavaType(F.getArg(0), Tail), JavaType(9, false));
  Analysis.clear();
  EXPECT_EQ(Stats.CurrentBaseEntries, 0U);
  EXPECT_EQ(Stats.CurrentDefinedEntries, 0U);
  EXPECT_EQ(Stats.CurrentPathFactsEntries, 0U);
  EXPECT_EQ(Stats.CurrentFinalTypeEntries, 0U);
  EXPECT_FALSE(verifyModule(*M, &errs()));
}

TEST_F(CachedJavaTypeTest, FinalClearsAcrossRealLVIColdAndPrewarmedEpochs) {
  auto M = parse(R"IR(
    define ptr @test(ptr "java-klass"="9" %typed, i1 noundef %choose) {
    entry:
      br i1 %choose, label %nullpath, label %typedpath
    nullpath:
      br label %merge
    typedpath:
      br label %merge
    merge:
      %result = phi ptr [ null, %nullpath ], [ %typed, %typedpath ]
      ret ptr %result
    }
  )IR");
  ASSERT_NE(M, nullptr);
  Function &F = *M->getFunction("test");
  BasicBlock *NullPath = findFactsTestBlock(F, "nullpath");
  BasicBlock *Merge = findFactsTestBlock(F, "merge");
  Instruction *At = Merge->getTerminator();
  auto *Phi = cast<PHINode>(&Merge->front());
  auto *Null = ConstantPointerNull::get(PointerType::get(Context, 0));
  Value *Previous = Null;
  SmallVector<Value *, 8> Checkpoints;
  for (unsigned I = 1; I <= 600; ++I) {
    Previous = SelectInst::Create(F.getArg(1), Previous, Null, "null.select",
                                  F.front().getTerminator()->getIterator());
    if (I % 100 == 0)
      Checkpoints.push_back(Previous);
  }
  Phi->setIncomingValue(0, Previous);
  ASSERT_FALSE(verifyModule(*M, &errs()));

  DominatorTree DT(F);
  AssumptionCache AC(F);
  LazyValueInfo LVI(&AC, &M->getDataLayout());
  unsigned Calls = 0;
  auto Oracle = [&](Value *V, BasicBlock *From, BasicBlock *To) {
    ++Calls;
    return LVINullEdgeOracle{LVI}(V, From, To);
  };
  JavaTypeCache Cache(F, FactsCacheMode::StableOracleEpoch);
  Cache.setStatsEnabled(true);
  // The 600-value proof exceeds LVI's per-solve work limit in a cold instance.
  EXPECT_TRUE(getCachedJavaType(Phi, &DT, At, Oracle, Cache).isUnknown());
  unsigned ColdCalls = Calls;
  EXPECT_TRUE(getCachedJavaType(Phi, &DT, At, Oracle, Cache).isUnknown());
  EXPECT_EQ(Calls, ColdCalls);
  EXPECT_EQ(Cache.Final.getStats().Hits, 1U);

  Cache.notifyOracleChanged();
  LVI.clear();
  // Each smaller prefix completes within LVI's limit, leaving a reusable
  // predecessor result for the next prefix. The IR itself has not changed.
  for (Value *V : Checkpoints)
    EXPECT_TRUE(LVINullEdgeOracle{LVI}(V, NullPath, Merge));
  EXPECT_EQ(Cache.finalTypesSize(), 0U);
  EXPECT_EQ(getCachedJavaType(Phi, &DT, At, Oracle, Cache), JavaType(9, false));
  EXPECT_EQ(Cache.Final.getStats().Misses, 2U);
  EXPECT_EQ(getJavaType(Phi, &DT, At, LVINullEdgeOracle{LVI}),
            JavaType(9, false));

  Cache.notifyOracleChanged();
  LVI.clear();
  EXPECT_EQ(Cache.finalTypesSize(), 0U);
  EXPECT_TRUE(getCachedJavaType(Phi, &DT, At, Oracle, Cache).isUnknown());
  EXPECT_EQ(Cache.Final.getStats().Misses, 3U);
  AssumptionCache FreshAC(F);
  LazyValueInfo FreshLVI(&FreshAC, &M->getDataLayout());
  EXPECT_TRUE(
      getJavaType(Phi, &DT, At, LVINullEdgeOracle{FreshLVI}).isUnknown());
}

TEST_F(CachedJavaTypeTest,
       FinalCachesDeepIdentityChainsWithoutDependencyLimit) {
  auto M = parse(R"IR(
    define ptr @test(ptr "java-klass"="9" "java-klass-exact" %obj) {
      ret ptr %obj
    }
  )IR");
  ASSERT_NE(M, nullptr);
  Function &F = *M->getFunction("test");
  Instruction *At = F.front().getTerminator();
  Value *Previous = F.getArg(0);
  Value *Zero = ConstantInt::get(Type::getInt64Ty(Context), 0);
  for (unsigned I = 0; I < 4100; ++I)
    Previous = GetElementPtrInst::Create(Type::getInt8Ty(Context), Previous,
                                         {Zero}, "identity", At->getIterator());
  cast<ReturnInst>(At)->setOperand(0, Previous);
  ASSERT_FALSE(verifyModule(*M, &errs()));
  DominatorTree DT(F);
  JavaTypeCache Cache(F, FactsCacheMode::StableOracleEpoch);
  Cache.setStatsEnabled(true);
  EXPECT_EQ(getCachedJavaType(F.getArg(0), &DT, At, noNullEdge, Cache),
            JavaType(9, true));
  ASSERT_EQ(Cache.finalTypesSize(), 1U);
  JavaType Expected = getJavaType(Previous, &DT, At, noNullEdge);
  EXPECT_EQ(Expected, JavaType(9, true));
  for (unsigned I = 0; I < 2; ++I) {
    EXPECT_EQ(getCachedJavaType(Previous, &DT, At, noNullEdge, Cache),
              Expected);
    EXPECT_EQ(Cache.finalTypesSize(), 2U);
    EXPECT_EQ(Cache.Final.getStats().Misses, 2U);
    EXPECT_EQ(Cache.Final.getStats().Hits, I);
  }
  EXPECT_EQ(getCachedJavaType(F.getArg(0), &DT, At, noNullEdge, Cache),
            JavaType(9, true));
  EXPECT_EQ(Cache.Final.getStats().Hits, 2U);
}

TEST_F(CachedJavaTypeTest, SharedPathsReusePrefixesAcrossBudgetsAndEpochs) {
  auto M = parse(R"IR(
    declare i1 @jeandle.check_instanceof(ptr, ptr nonnull)
    define ptr @test(ptr %obj) {
    entry:
      %check = call i1 @jeandle.check_instanceof(
          ptr inttoptr(i64 9 to ptr), ptr %obj)
      br i1 %check, label %first, label %reject
    first:
      br label %second
    second:
      br label %exit
    exit:
      ret ptr %obj
    reject:
      ret ptr null
    }
  )IR");
  ASSERT_NE(M, nullptr);
  Function &F = *M->getFunction("test");
  DominatorTree DT(F);
  auto *Option =
      cl::getRegisteredOptions().lookup("jeandle-max-facts-join-blocks");
  ASSERT_NE(Option, nullptr);
  auto &Budget = *static_cast<cl::opt<unsigned> *>(Option);
  unsigned Saved = Budget;
  auto Restore = make_scope_exit([&] { Budget = Saved; });
  Budget = 128;
  JavaTypeCache Cache(F, FactsCacheMode::StableOracleEpoch);
  Cache.setFinalEnabled(false);
  Cache.setStatsEnabled(true);
  unsigned Calls = 0;
  auto Oracle = [&](Value *, BasicBlock *, BasicBlock *) {
    ++Calls;
    return false;
  };
  auto Query = [&](StringRef Name) {
    Instruction *At = findFactsTestBlock(F, Name)->getTerminator();
    JavaType Actual = getCachedJavaType(F.getArg(0), &DT, At, Oracle, Cache);
    EXPECT_EQ(Actual, getJavaType(F.getArg(0), &DT, At, noNullEdge));
    return Actual;
  };
  EXPECT_EQ(Query("first"), JavaType(9, false));
  EXPECT_EQ(Query("second"), JavaType(9, false));
  EXPECT_EQ(Query("exit"), JavaType(9, false));
  EXPECT_EQ(Calls, 3U);
  EXPECT_EQ(Cache.Facts.getStats().PathHits, 2U);
  EXPECT_EQ(Cache.Facts.pathSize(), 3U);
  Budget = 1;
  Instruction *At = findFactsTestBlock(F, "exit")->getTerminator();
  EXPECT_TRUE(getJavaType(F.getArg(0), &DT, At, noNullEdge).isUnknown());
  // A complete cached path remains valid with less solving budget. Reusing it
  // can retain facts which a cold query with that budget would not discover.
  EXPECT_EQ(getCachedJavaType(F.getArg(0), &DT, At, Oracle, Cache),
            JavaType(9, false));
  EXPECT_EQ(Cache.Facts.getStats().PathHits, 3U);
  Budget = 128;
  EXPECT_EQ(Query("exit"), JavaType(9, false));
  Cache.notifyOracleChanged();
  EXPECT_EQ(Cache.Facts.pathSize(), 0U);
  auto *Check = cast<CallInst>(findBaseTestInstruction(F, "check"));
  Cache.invalidate({Check});
  Check->setArgOperand(0, ConstantExpr::getIntToPtr(
                              ConstantInt::get(Type::getInt64Ty(Context), 22),
                              PointerType::get(Context, 0)));
  EXPECT_EQ(Query("exit"), JavaType(22, false));
  Cache.clear();
  EXPECT_EQ(Cache.Facts.pathSize(), 0U);
}

TEST_F(CachedJavaTypeTest, SharedPathsDoNotPublishIrreducibleCycleResults) {
  auto M = parse(R"IR(
    declare i1 @jeandle.check_instanceof(ptr, ptr nonnull)
    define ptr @test(ptr %obj, i1 %pick, i1 %again) {
    entry:
      br i1 %pick, label %a, label %b
    a:
      %check = call i1 @jeandle.check_instanceof(
          ptr inttoptr(i64 9 to ptr), ptr %obj)
      br i1 %check, label %b, label %exit
    b:
      br i1 %again, label %a, label %exit
    exit:
      ret ptr %obj
    }
  )IR");
  ASSERT_NE(M, nullptr);
  Function &F = *M->getFunction("test");
  DominatorTree DT(F);
  JavaTypeCache Cache(F, FactsCacheMode::StableOracleEpoch);
  Cache.setFinalEnabled(false);
  for (StringRef Name : {"exit", "a", "b", "b", "a", "exit"}) {
    Instruction *At = findFactsTestBlock(F, Name)->getTerminator();
    EXPECT_EQ(getCachedJavaType(F.getArg(0), &DT, At, noNullEdge, Cache),
              getJavaType(F.getArg(0), &DT, At, noNullEdge));
  }
  EXPECT_EQ(Cache.Facts.pathSize(), 0U);
}

TEST_F(CachedJavaTypeTest, EntrySelectChainReusesBaseWithoutRewalkingInputs) {
  std::string IR = "define ptr @test(ptr \"java-klass\"=\"9\" %a, ptr "
                   "\"java-klass\"=\"9\" %b, i1 %c) {\nentry:\n";
  std::string Previous = "%a";
  for (unsigned I = 0; I < 64; ++I) {
    std::string Name = "%s" + std::to_string(I);
    IR += Name + " = select i1 %c, ptr " + Previous + ", ptr %b\n";
    Previous = Name;
  }
  IR += "br label %exit\nexit:\nret ptr " + Previous + "\n}\n";
  auto M = parse(IR);
  ASSERT_NE(M, nullptr);
  Function &F = *M->getFunction("test");
  DominatorTree DT(F);
  Instruction *At = F.back().getTerminator();
  Value *V = returnedValue(F);
  JavaTypeCache Cache(F, FactsCacheMode::StableOracleEpoch);
  Cache.setFinalEnabled(false);
  Cache.setStatsEnabled(true);
  EXPECT_EQ(getCachedJavaType(V, &DT, At, noNullEdge, Cache),
            JavaType(9, false));
  Cache.Base.resetStats();
  EXPECT_EQ(getCachedJavaType(V, &DT, At, noNullEdge, Cache),
            getJavaType(V, &DT, At, noNullEdge));
  EXPECT_EQ(Cache.Base.getStats().Hits, 1U);
  EXPECT_EQ(Cache.Base.getStats().NodesEvaluated, 0U);
}

TEST_F(CachedJavaTypeTest, SelectOutsideEntryKeepsDefinitionPointRefinement) {
  auto M = parse(R"IR(
    declare i1 @jeandle.check_instanceof(ptr, ptr nonnull)
    define ptr @test(ptr %obj, i1 %choose) {
    entry:
      %check = call i1 @jeandle.check_instanceof(
          ptr inttoptr(i64 9 to ptr), ptr %obj)
      br i1 %check, label %good, label %reject
    good:
      %s = select i1 %choose, ptr %obj, ptr %obj
      br label %exit
    exit:
      ret ptr %s
    reject:
      ret ptr null
    }
  )IR");
  ASSERT_NE(M, nullptr);
  Function &F = *M->getFunction("test");
  DominatorTree DT(F);
  Value *V = findBaseTestInstruction(F, "s");
  Instruction *At = findFactsTestBlock(F, "exit")->getTerminator();
  JavaTypeCache Cache(F, FactsCacheMode::StableOracleEpoch);
  Cache.setFinalEnabled(false);
  for (unsigned I = 0; I < 2; ++I) {
    EXPECT_EQ(getCachedJavaType(V, &DT, At, noNullEdge, Cache),
              JavaType(9, false));
    EXPECT_EQ(getCachedJavaType(V, &DT, At, noNullEdge, Cache),
              getJavaType(V, &DT, At, noNullEdge));
  }
}

TEST_F(CachedJavaTypeTest, SharedPathsReuseSmallSlicesAfterCFGExpansion) {
  auto M = parse(R"IR(
    declare i1 @jeandle.check_instanceof(ptr, ptr nonnull)
    define ptr @test(ptr %obj) {
    entry:
      %check = call i1 @jeandle.check_instanceof(
          ptr inttoptr(i64 9 to ptr), ptr %obj)
      br i1 %check, label %good, label %reject
    good:
      br label %exit
    exit:
      ret ptr %obj
    reject:
      ret ptr null
    }
  )IR");
  ASSERT_NE(M, nullptr);
  Function &F = *M->getFunction("test");
  DominatorTree DT(F);
  auto *Option =
      cl::getRegisteredOptions().lookup("jeandle-max-facts-join-blocks");
  ASSERT_NE(Option, nullptr);
  auto &Budget = *static_cast<cl::opt<unsigned> *>(Option);
  unsigned Saved = Budget;
  auto Restore = make_scope_exit([&] { Budget = Saved; });
  Budget = 2;
  ASSERT_GT(F.size(), Budget);
  JavaTypeCache Cache(F, FactsCacheMode::StableOracleEpoch);
  Cache.setFinalEnabled(false);
  BasicBlock *Exit = findFactsTestBlock(F, "exit");
  EXPECT_EQ(getCachedJavaType(F.getArg(0), &DT, Exit->getTerminator(),
                              noNullEdge, Cache),
            JavaType(9, false));
  EXPECT_EQ(Cache.Facts.pathSize(), 2U);
  Cache.invalidate({}, /*CFGChanged=*/true);
  EXPECT_EQ(Cache.Facts.pathSize(), 0U);
  auto *Previous =
      cast<BranchInst>(findFactsTestBlock(F, "good")->getTerminator());
  SmallVector<BasicBlock *, 8> Added;
  for (unsigned I = 0; I < 6; ++I) {
    auto *BB =
        BasicBlock::Create(Context, "extra" + std::to_string(I), &F, Exit);
    BranchInst::Create(Exit, BB);
    Previous->setSuccessor(0, BB);
    Previous = cast<BranchInst>(BB->getTerminator());
    Added.push_back(BB);
  }
  Added.push_back(Exit);
  DT.recalculate(F);
  EXPECT_FALSE(verifyModule(*M, &errs()));
  for (unsigned I = 0; I < 2; ++I)
    for (BasicBlock *BB : Added)
      EXPECT_EQ(getCachedJavaType(F.getArg(0), &DT, BB->getTerminator(),
                                  noNullEdge, Cache),
                JavaType(9, false));
  EXPECT_TRUE(getJavaType(F.getArg(0), &DT, Exit->getTerminator(), noNullEdge)
                  .isUnknown());
  EXPECT_EQ(Cache.Facts.pathSize(), Added.size() + 1);
}

TEST_F(CachedJavaTypeTest, SharedPathsDoNotPublishBudgetTruncatedParents) {
  auto M = parse(R"IR(
    declare i1 @jeandle.check_instanceof(ptr, ptr nonnull)
    define ptr @test(ptr %obj) {
    entry:
      %check = call i1 @jeandle.check_instanceof(
          ptr inttoptr(i64 9 to ptr), ptr %obj)
      br i1 %check, label %good, label %reject
    good:
      br label %middle
    middle:
      br label %exit
    exit:
      ret ptr %obj
    reject:
      ret ptr null
    }
  )IR");
  ASSERT_NE(M, nullptr);
  Function &F = *M->getFunction("test");
  DominatorTree DT(F);
  auto *Option =
      cl::getRegisteredOptions().lookup("jeandle-max-facts-join-blocks");
  ASSERT_NE(Option, nullptr);
  auto &Budget = *static_cast<cl::opt<unsigned> *>(Option);
  unsigned Saved = Budget;
  auto Restore = make_scope_exit([&] { Budget = Saved; });
  JavaTypeCache Cache(F, FactsCacheMode::StableOracleEpoch);
  Cache.setFinalEnabled(false);
  Instruction *At = findFactsTestBlock(F, "exit")->getTerminator();
  Budget = 1;
  for (unsigned I = 0; I < 2; ++I) {
    EXPECT_TRUE(
        getCachedJavaType(F.getArg(0), &DT, At, noNullEdge, Cache).isUnknown());
    EXPECT_EQ(Cache.Facts.pathSize(), 0U);
  }
  Budget = 128;
  EXPECT_EQ(getCachedJavaType(F.getArg(0), &DT, At, noNullEdge, Cache),
            JavaType(9, false));
  EXPECT_EQ(Cache.Facts.pathSize(), 3U);
}

TEST_F(CachedJavaTypeTest, AnalysisVerifierDistinguishesTruncatedColdQueries) {
  auto M = parse(R"IR(
    declare i1 @jeandle.check_instanceof(ptr, ptr nonnull)
    define ptr @test(ptr %obj) {
    entry:
      %check = call i1 @jeandle.check_instanceof(
          ptr inttoptr(i64 9 to ptr), ptr %obj)
      br i1 %check, label %good, label %reject
    good:
      br label %middle
    middle:
      br label %exit
    exit:
      ret ptr %obj
    reject:
      ret ptr null
    }
  )IR");
  ASSERT_NE(M, nullptr);
  auto &Options = cl::getRegisteredOptions();
  auto *BudgetOption = Options.lookup("jeandle-max-facts-join-blocks");
  auto *StatsOption = Options.lookup("jeandle-java-type-stats");
  auto *VerifyOption = Options.lookup("jeandle-verify-java-type-cache");
  ASSERT_NE(BudgetOption, nullptr);
  ASSERT_NE(StatsOption, nullptr);
  ASSERT_NE(VerifyOption, nullptr);
  auto &Budget = *static_cast<cl::opt<unsigned> *>(BudgetOption);
  auto &CollectStats = *static_cast<cl::opt<bool> *>(StatsOption);
  auto &Verify = *static_cast<cl::opt<bool> *>(VerifyOption);
  unsigned SavedBudget = Budget;
  bool SavedStats = CollectStats;
  bool SavedVerify = Verify;
  auto Restore = make_scope_exit([&] {
    Budget = SavedBudget;
    CollectStats = SavedStats;
    Verify = SavedVerify;
  });
  Budget = 128;
  CollectStats = true;
  Verify = true;

  Function &F = *M->getFunction("test");
  FunctionAnalysisManager FAM;
  PassBuilder PB;
  PB.registerFunctionAnalyses(FAM);
  auto &Analysis = FAM.getResult<JavaTypeAnalysis>(F);
  const auto &Stats = FAM.getResult<JavaTypeStatsAnalysis>(F).getStats();
  Instruction *Middle = findFactsTestBlock(F, "middle")->getTerminator();
  Instruction *Exit = findFactsTestBlock(F, "exit")->getTerminator();
  EXPECT_EQ(Analysis.getJavaType(F.getArg(0), Middle), JavaType(9, false));
  EXPECT_EQ(Stats.Verifications, 1U);

  Budget = 1;
  DominatorTree DT(F);
  EXPECT_TRUE(getJavaType(F.getArg(0), &DT, Exit, noNullEdge).isUnknown());
  // Exit has no Final entry. Its query reuses the complete middle path,
  // whereas the independently checked cold query cannot reach the guard.
  EXPECT_EQ(Analysis.getJavaType(F.getArg(0), Exit), JavaType(9, false));
  EXPECT_EQ(Stats.Queries, 2U);
  EXPECT_EQ(Stats.FinalHits, 0U);
  EXPECT_EQ(Stats.FinalMisses, 2U);
  EXPECT_EQ(Stats.Verifications, 1U);
}

TEST_F(CachedJavaTypeTest, SharedPathsReuseInstructionAndPhiPrefixes) {
  auto M = parse(R"IR(
    declare i1 @jeandle.check_instanceof(ptr, ptr nonnull)
    define ptr @test(ptr %slot, i1 %pick) {
    entry:
      %loaded = load ptr, ptr %slot
      %check = call i1 @jeandle.check_instanceof(
          ptr inttoptr(i64 9 to ptr), ptr %loaded)
      br i1 %check, label %good, label %reject
    good:
      br i1 %pick, label %left, label %right
    left:
      br label %merge
    right:
      br label %merge
    merge:
      %joined = phi ptr [ %loaded, %left ], [ %loaded, %right ]
      br label %tail
    tail:
      br label %exit
    exit:
      ret ptr %joined
    reject:
      ret ptr null
    }
  )IR");
  ASSERT_NE(M, nullptr);
  Function &F = *M->getFunction("test");
  DominatorTree DT(F);
  JavaTypeCache Cache(F, FactsCacheMode::StableOracleEpoch);
  Cache.setFinalEnabled(false);
  Cache.setStatsEnabled(true);
  Value *Loaded = findBaseTestInstruction(F, "loaded");
  Value *Joined = findBaseTestInstruction(F, "joined");
  auto Query = [&](Value *V, StringRef Name) {
    Instruction *At = findFactsTestBlock(F, Name)->getTerminator();
    JavaType Actual = getCachedJavaType(V, &DT, At, noNullEdge, Cache);
    EXPECT_EQ(Actual, getJavaType(V, &DT, At, noNullEdge));
    EXPECT_EQ(Actual, JavaType(9, false));
  };
  Query(Loaded, "good");
  EXPECT_NE(Cache.Facts.lookupPath(Loaded, findFactsTestBlock(F, "good")),
            nullptr);
  uint64_t Hits = Cache.Facts.getStats().PathHits;
  Query(Loaded, "left");
  EXPECT_GT(Cache.Facts.getStats().PathHits, Hits);
  Query(Joined, "tail");
  // The PHI's definition-block facts are empty, but its completed tail facts
  // are independent of the PHI evaluation stack and can be reused at exit.
  EXPECT_NE(Cache.Facts.lookupPath(Joined, findFactsTestBlock(F, "tail")),
            nullptr);
  Hits = Cache.Facts.getStats().PathHits;
  Query(Joined, "exit");
  EXPECT_GT(Cache.Facts.getStats().PathHits, Hits);
}

} // namespace

TEST_F(CachedJavaTypeTest,
       ProvenContextPreservationRetainsFinalAndOracleEpoch) {
  auto M = parse(R"IR(
    define ptr @test(ptr "java-klass"="9" %obj, i32 %n) {
    entry:
      %noise = add i32 %n, 1
      br label %tail
    tail:
      ret ptr %obj
    }
  )IR");
  ASSERT_NE(M, nullptr);
  Function &F = *M->getFunction("test");
  DominatorTree DT(F);
  auto *Noise = findBaseTestInstruction(F, "noise");
  ASSERT_TRUE(Noise->use_empty());
  JavaTypeCache Cache(F, FactsCacheMode::StableOracleEpoch);
  Cache.setStatsEnabled(true);
  auto *At = F.back().getTerminator();
  for (unsigned I = 0; I != 32; ++I) {
    if (I) {
      auto Removed = Cache.invalidate(
          {Noise}, false, JavaTypeBaseInvalidationMode::SelectiveKeys,
          JavaTypeContextPreservation::Preserved);
      EXPECT_EQ(Removed.FinalRemoved, 0U);
      Noise->setOperand(
          1, ConstantInt::get(Type::getInt32Ty(Context), 1 + (I & 1)));
    }
    EXPECT_EQ(getCachedJavaType(F.getArg(0), &DT, At, noNullEdge, Cache),
              getJavaType(F.getArg(0), &DT, At, noNullEdge));
  }
  EXPECT_EQ(Cache.Final.getStats().Hits, 31U);
  getCachedJavaType(Noise, &DT, At, noNullEdge, Cache);
  auto Removed = Cache.invalidate({Noise}, false,
                                  JavaTypeBaseInvalidationMode::SelectiveKeys,
                                  JavaTypeContextPreservation::Preserved);
  EXPECT_EQ(Removed.FinalRemoved, 1U);
  EXPECT_NE(Cache.Final.lookup(F.getArg(0), At->getParent()), nullptr);
  Cache.invalidate({Noise}, true, JavaTypeBaseInvalidationMode::SelectiveKeys,
                   JavaTypeContextPreservation::Preserved);
  EXPECT_EQ(Cache.finalTypesSize(), 0U);
  getCachedJavaType(F.getArg(0), &DT, At, noNullEdge, Cache);
  Cache.notifyOracleChanged();
  EXPECT_EQ(Cache.finalTypesSize(), 0U);
  getCachedJavaType(F.getArg(0), &DT, At, noNullEdge, Cache);
  Cache.invalidate({Noise});
  EXPECT_EQ(Cache.finalTypesSize(), 0U);
}

TEST_F(CachedJavaTypeTest, AnalysisExplicitPreservationRetainsFinal) {
  auto M = parse(R"IR(
    define ptr @test(ptr "java-klass"="9" %obj, i32 %n) {
    entry:
      %noise = add i32 %n, 1
      br label %tail
    tail:
      ret ptr %obj
    }
  )IR");
  ASSERT_NE(M, nullptr);
  auto *Option = cl::getRegisteredOptions().lookup("jeandle-java-type-stats");
  ASSERT_NE(Option, nullptr);
  auto &Collect = *static_cast<cl::opt<bool> *>(Option);
  bool Saved = Collect;
  auto Restore = make_scope_exit([&] { Collect = Saved; });
  Collect = true;
  Function &F = *M->getFunction("test");
  FunctionAnalysisManager FAM;
  PassBuilder PB;
  PB.registerFunctionAnalyses(FAM);
  auto &Analysis = FAM.getResult<JavaTypeAnalysis>(F);
  const auto &Stats = FAM.getResult<JavaTypeStatsAnalysis>(F).getStats();
  Instruction *Noise = findBaseTestInstruction(F, "noise");
  auto *At = F.back().getTerminator();
  EXPECT_EQ(Analysis.getJavaType(F.getArg(0), At), JavaType(9, false));
  Analysis.invalidatePreservingContext(*Noise);
  Noise->setOperand(1, ConstantInt::get(Type::getInt32Ty(Context), 2));
  EXPECT_EQ(Analysis.getJavaType(F.getArg(0), At), JavaType(9, false));
  EXPECT_EQ(Stats.FinalHits, 1U);
  Analysis.invalidate(*Noise);
  Noise->setOperand(1, ConstantInt::get(Type::getInt32Ty(Context), 3));
  EXPECT_EQ(Analysis.getJavaType(F.getArg(0), At), JavaType(9, false));
  EXPECT_EQ(Stats.FinalHits, 1U);
  EXPECT_EQ(Stats.FinalMisses, 2U);
}
