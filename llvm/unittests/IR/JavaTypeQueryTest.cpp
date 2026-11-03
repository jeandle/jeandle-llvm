//===- JavaTypeQueryTest.cpp - Java 类型共享缓存测试 ---------------------===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#include "llvm/Analysis/Jeandle/CachedJavaType.h"
#include "llvm/Analysis/Jeandle/JavaTypeAnalysis.h"
#include "llvm/Analysis/Jeandle/JavaTypeAnalysisStats.h"
#include "llvm/Analysis/Jeandle/LVINullEdgeOracle.h"
#include "llvm/Analysis/LazyValueInfo.h"
#include "llvm/AsmParser/Parser.h"
#include "llvm/IR/Dominators.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/Jeandle/VMCallback.h"
#include "llvm/IR/Jeandle/VMConstants.h"
#include "llvm/IR/LLVMContext.h"
#include "llvm/IR/Metadata.h"
#include "llvm/IR/Module.h"
#include "llvm/IR/Verifier.h"
#include "llvm/Passes/PassBuilder.h"
#include "llvm/Support/CommandLine.h"
#include "llvm/Support/SourceMgr.h"
#include "llvm/Support/raw_ostream.h"
#include "llvm/Transforms/Jeandle/ConstantFieldFolding.h"
#include "llvm/Transforms/Jeandle/CopySpecialization.h"
#include "gtest/gtest.h"

#include <algorithm>
#include <string>

using namespace llvm;
using namespace llvm::jeandle;

namespace {

// 单个测试临时调整查询选项，结束后恢复，不影响其他测试。
template <typename T> class ScopedQueryOption {
  cl::opt<T> &Option;
  T Saved;

public:
  ScopedQueryOption(StringRef Name, T Value)
      : Option(*static_cast<cl::opt<T> *>(cl::getRegisteredOptions().lookup(Name))),
        Saved(Option.getValue()) {
    Option = Value;
  }
  ~ScopedQueryOption() { Option = Saved; }
};

class JavaTypeQueryTest : public testing::Test {
protected:
  LLVMContext C;
  std::unique_ptr<Module> M;
  std::unique_ptr<ScopedQueryOption<bool>> StatisticsFlag;
  VMCallbacks Saved{};

  void SetUp() override {
    if (const auto *CB = getVMCallbacks())
      Saved = *CB;
    VMCallbacks CB{};
    CB.IsSubtype = [](uintptr_t A, uintptr_t B) { return A == B || B == 1; };
    CB.IsInterface = [](uintptr_t) { return false; };
    CB.IsEffectivelyFinal = [](uintptr_t) { return false; };
    CB.GetSecondarySupers = [](uintptr_t) { return std::vector<uintptr_t>{}; };
    CB.GetCommonSuperKlass = [](uintptr_t A, uintptr_t B) {
      return A == B ? A : uintptr_t(1);
    };
    registerVMCallbacks(CB);
    // Statistics are off by default; these tests observe counters and cache
    // sizes, so enable them explicitly.
    StatisticsFlag = std::make_unique<ScopedQueryOption<bool>>(
        "jeandle-java-type-stats", true);
  }

  void TearDown() override {
    StatisticsFlag.reset();
    registerVMCallbacks(Saved);
  }

  Function *parse(StringRef IR) {
    SMDiagnostic Error;
    M = parseAssemblyString(IR, Error, C);
    return M ? M->getFunction("test") : nullptr;
  }

  BasicBlock *block(Function &F, StringRef Name) {
    for (BasicBlock &BB : F)
      if (BB.getName() == Name)
        return &BB;
    return nullptr;
  }

  // Statistics were split out of the analysis result; queries and invalidations
  // are reported to the statistics analysis through the observer.
  std::string statistics(FunctionAnalysisManager &FAM, Function *F) {
    std::string Text;
    raw_string_ostream OS(Text);
    FAM.getResult<JavaTypeStatsAnalysis>(*F).print(OS);
    return Text;
  }

  // 两个查询位置共享 guard -> hit 的类型事实。
  static constexpr const char *IR = R"(
    declare i1 @jeandle.check_instanceof(ptr, ptr nonnull)
    define void @test(ptr %obj, i1 %unrelated) {
    entry:
      br label %guard
    guard:
      %check = call i1 @jeandle.check_instanceof(ptr inttoptr (i64 22 to ptr), ptr %obj)
      br i1 %check, label %hit, label %miss
    hit:
      br label %tail
    tail:
      ret void
    miss:
      ret void
    }
  )";
};

TEST_F(JavaTypeQueryTest, IrreducibleCycleCachesCompletedTopLevelResult) {
  Function *F = parse(R"(
    define void @test(ptr %obj, i1 %c) {
    entry:
      br i1 %c, label %a, label %b
    a:
      br label %b
    b:
      br label %a
    }
  )");
  ASSERT_NE(F, nullptr);
  Value *V = F->getArg(0);
  FunctionAnalysisManager FAM;
  PassBuilder PB;
  PB.registerFunctionAnalyses(FAM);
  auto &Result = FAM.getResult<JavaTypeAnalysis>(*F);
  EXPECT_TRUE(Result.getJavaType(V, block(*F, "a")->getTerminator()).isUnknown());
  EXPECT_NE(statistics(FAM, F).find("current final type entries: 1"),
            std::string::npos);
}

TEST_F(JavaTypeQueryTest, ResultInvalidationAfterConditionAndAttributeChange) {
  Function *F = parse(IR);
  ASSERT_NE(F, nullptr);
  FunctionAnalysisManager FAM;
  PassBuilder PB;
  PB.registerFunctionAnalyses(FAM);
  auto &Result = FAM.getResult<JavaTypeAnalysis>(*F);
  Value *V = F->getArg(0);
  Instruction *Context = block(*F, "tail")->getTerminator();
  EXPECT_EQ(Result.getJavaType(V, Context).Klass, 22U);
  EXPECT_EQ(Result.getJavaType(V, Context).Klass, 22U);
  EXPECT_TRUE(Result.getJavaType(V).isUnknown());

  // The queried value is unchanged; its controlling branch is a dependency.
  auto *Branch = cast<BranchInst>(block(*F, "guard")->getTerminator());
  Result.invalidate(*Branch);
  Branch->setCondition(F->getArg(1));
  EXPECT_NE(statistics(FAM, F).find("current final type entries: 0"),
            std::string::npos);
  FAM.getResult<LazyValueAnalysis>(*F).clear();
  EXPECT_TRUE(Result.getJavaType(V, Context).isUnknown());

  F->addParamAttr(0, Attribute::get(C, "java-klass", "22"));
  Result.clear();
  EXPECT_EQ(Result.getJavaType(V).Klass, 22U);
}

TEST_F(JavaTypeQueryTest, FinalTypesAreKeyedByContextBlock) {
  ScopedQueryOption<bool> Verify("jeandle-verify-java-type-cache", true);
  Function *F = parse(IR);
  ASSERT_NE(F, nullptr);
  FunctionAnalysisManager FAM;
  PassBuilder PB;
  PB.registerFunctionAnalyses(FAM);
  auto &Result = FAM.getResult<JavaTypeAnalysis>(*F);
  Value *V = F->getArg(0);
  BasicBlock *Guard = block(*F, "guard");
  // 同一 BB 内不同指令共用最终缓存；完整的 unknown 也可缓存。
  EXPECT_TRUE(Result.getJavaType(V, &Guard->front()).isUnknown());
  EXPECT_TRUE(Result.getJavaType(V, Guard->getTerminator()).isUnknown());
  EXPECT_EQ(Result.getJavaType(V, block(*F, "hit")->getTerminator()).Klass, 22U);
  EXPECT_NE(statistics(FAM, F).find("final type hits: 1"), std::string::npos);
  EXPECT_NE(statistics(FAM, F).find("current final type entries: 2"),
            std::string::npos);
  Result.clear();
  EXPECT_NE(statistics(FAM, F).find("current final type entries: 0"),
            std::string::npos);
  EXPECT_NE(statistics(FAM, F).find("current edge facts entries: 0"),
            std::string::npos);
  EXPECT_NE(statistics(FAM, F).find("current base entries: 0"),
            std::string::npos);
}

TEST_F(JavaTypeQueryTest, FinalCacheDoesNotReplacePhiIncomingEvaluation) {
  ScopedQueryOption<bool> Verify("jeandle-verify-java-type-cache", true);
  Function *F = parse(R"(
    declare i1 @jeandle.check_instanceof(ptr, ptr nonnull)
    define void @test(ptr "java-klass"="1" %obj) {
    entry:
      %check = call i1 @jeandle.check_instanceof(ptr inttoptr (i64 22 to ptr), ptr %obj)
      br i1 %check, label %hit, label %miss
    hit:
      %p = phi ptr [ %obj, %entry ]
      ret void
    miss:
      ret void
    }
  )");
  ASSERT_NE(F, nullptr);
  FunctionAnalysisManager FAM;
  PassBuilder PB;
  PB.registerFunctionAnalyses(FAM);
  auto &Result = FAM.getResult<JavaTypeAnalysis>(*F);
  EXPECT_EQ(Result.getJavaType(F->getArg(0), F->getEntryBlock().getTerminator()).Klass,
            1U);
  BasicBlock *Hit = block(*F, "hit");
  EXPECT_EQ(Result.getJavaType(&Hit->front(), Hit->getTerminator()).Klass, 22U);
  EXPECT_NE(statistics(FAM, F).find("final type hits: 0"), std::string::npos);
  EXPECT_NE(statistics(FAM, F).find("current final type entries: 2"),
            std::string::npos);
  EXPECT_EQ(FAM.getResult<JavaTypeStatsAnalysis>(*F).getStats().Verifications,
            2U);
}

TEST_F(JavaTypeQueryTest, PhiCycleIntermediateIsNotPublished) {
  ScopedQueryOption<bool> Verify("jeandle-verify-java-type-cache", true);
  Function *F = parse(R"(
    define void @test(ptr "java-klass"="22" %cat, ptr "java-klass"="33" %dog) {
    entry:
      br label %loop
    loop:
      %a = phi ptr [ %cat, %entry ], [ %b, %latch ]
      %b = phi ptr [ %dog, %entry ], [ %a, %latch ]
      br label %latch
    latch:
      br label %loop
    }
  )");
  ASSERT_NE(F, nullptr);
  FunctionAnalysisManager FAM;
  PassBuilder PB;
  PB.registerFunctionAnalyses(FAM);
  auto &Result = FAM.getResult<JavaTypeAnalysis>(*F);
  BasicBlock *Loop = block(*F, "loop");
  Value *A = &Loop->front();
  Value *B = Loop->front().getNextNode();
  Instruction *Context = block(*F, "latch")->getTerminator();
  // 查询 a 时内部 b 的局部贡献是 Dog，但只能发布 a 的完整 Animal 结果。
  EXPECT_EQ(Result.getJavaType(A, Context).Klass, 1U);
  EXPECT_NE(statistics(FAM, F).find("current final type entries: 1"),
            std::string::npos);
  // A completed top-level result is not substituted for a recursive input.
  EXPECT_EQ(Result.getJavaType(B, Context).Klass, 1U);
  EXPECT_NE(statistics(FAM, F).find("final type hits: 0"), std::string::npos);
  EXPECT_NE(statistics(FAM, F).find("current final type entries: 2"),
            std::string::npos);
  EXPECT_EQ(Result.getJavaType(B, Context).Klass, 1U);
  EXPECT_NE(statistics(FAM, F).find("final type hits: 1"), std::string::npos);
  EXPECT_EQ(FAM.getResult<JavaTypeStatsAnalysis>(*F).getStats().Verifications,
            3U);
}

TEST_F(JavaTypeQueryTest, CompletePhiCachePreservesOriginalCyclePrecision) {
  ScopedQueryOption<bool> Verify("jeandle-verify-java-type-cache", true);
  Function *F = parse(R"(
    declare i1 @jeandle.check_instanceof(ptr, ptr nonnull)
    define void @test(ptr "java-klass"="22" %cat, ptr "java-klass"="33" %dog) {
    entry:
      br label %loop
    loop:
      %a = phi ptr [ %cat, %entry ], [ %b, %latch ]
      %b = phi ptr [ %dog, %entry ], [ %a, %latch ]
      br label %latch
    latch:
      %check = call i1 @jeandle.check_instanceof(ptr inttoptr (i64 22 to ptr), ptr %b)
      br i1 %check, label %loop, label %exit
    exit:
      ret void
    }
  )");
  ASSERT_NE(F, nullptr);
  FunctionAnalysisManager FAM;
  PassBuilder PB;
  PB.registerFunctionAnalyses(FAM);
  auto &Result = FAM.getResult<JavaTypeAnalysis>(*F);
  BasicBlock *Loop = block(*F, "loop");
  Value *A = &Loop->front();
  Value *B = Loop->front().getNextNode();
  Instruction *Context = block(*F, "latch")->getTerminator();
  // 冷查询中 b 的局部 Dog 贡献不能被不相关的 Cat guard 替换，a 得到 Animal。
  EXPECT_EQ(Result.getJavaType(A, Context).Klass, 1U);
  Result.clear();
  EXPECT_EQ(Result.getJavaType(B, Context).Klass, 1U);
  // Warming B must not substitute its completed result inside A's recursion.
  EXPECT_EQ(Result.getJavaType(A, Context).Klass, 1U);
  EXPECT_EQ(Result.getJavaType(A, Context).Klass, 1U);
  EXPECT_EQ(FAM.getResult<JavaTypeStatsAnalysis>(*F).getStats().Verifications,
            4U);
}

TEST_F(JavaTypeQueryTest, PhiWarmupOrderHonorsFiniteClassModel) {
  for (bool QueryAFirst : {true, false}) {
    SCOPED_TRACE(QueryAFirst ? "A then B" : "B then A");
    Function *F = parse(R"(
      define void @test(ptr "java-klass"="22" %cat,
                        ptr "java-klass"="33" %dog) {
      entry:
        br label %loop
      loop:
        %a = phi ptr [ %cat, %entry ], [ %b, %latch ]
        %b = phi ptr [ %dog, %entry ], [ %a, %latch ]
        br label %latch
      latch:
        %check = call i1 @jeandle.check_instanceof(ptr inttoptr (i64 22 to ptr), ptr %b)
        br i1 %check, label %loop, label %exit
      exit:
        ret void
      }
      declare i1 @jeandle.check_instanceof(ptr, ptr nonnull)
    )");
    ASSERT_NE(F, nullptr);
    FunctionAnalysisManager FAM;
    PassBuilder PB;
    PB.registerFunctionAnalyses(FAM);
    auto &Result = FAM.getResult<JavaTypeAnalysis>(*F);
    BasicBlock *Loop = block(*F, "loop");
    Value *A = &Loop->front();
    Value *B = Loop->front().getNextNode();
    Instruction *Context = block(*F, "latch")->getTerminator();

    JavaType TypeA;
    JavaType TypeB;
    if (QueryAFirst) {
      TypeA = Result.getJavaType(A, Context);
      TypeB = Result.getJavaType(B, Context);
    } else {
      TypeB = Result.getJavaType(B, Context);
      TypeA = Result.getJavaType(A, Context);
    }

    // The finite model is Object=1, Cat=22, Dog=33. A legal result may be
    // Object or the edge-narrowed Cat; Dog is not the common type of the
    // mutually recursive PHIs.
    for (JavaType Type : {TypeA, TypeB})
      EXPECT_TRUE(Type.Klass == 1U || Type.Klass == 22U);
    auto &DT = FAM.getResult<DominatorTreeAnalysis>(*F);
    auto &LVI = FAM.getResult<LazyValueAnalysis>(*F);
    LVINullEdgeOracle Oracle{LVI};
    EXPECT_EQ(TypeA, jeandle::getJavaType(A, &DT, Context, Oracle));
    EXPECT_EQ(TypeB, jeandle::getJavaType(B, &DT, Context, Oracle));
  }
}

TEST_F(JavaTypeQueryTest, FinalFactsResultsSurviveBudgetChangesUntilCleared) {
  Function *F = parse(IR);
  ASSERT_NE(F, nullptr);
  FunctionAnalysisManager FAM;
  PassBuilder PB;
  PB.registerFunctionAnalyses(FAM);
  auto &Result = FAM.getResult<JavaTypeAnalysis>(*F);
  Value *V = F->getArg(0);
  Instruction *Context = block(*F, "tail")->getTerminator();
  {
    ScopedQueryOption<unsigned> Budget("jeandle-max-facts-join-blocks", 1);
    EXPECT_TRUE(Result.getJavaType(V, Context).isUnknown());
    EXPECT_NE(statistics(FAM, F).find("current final type entries: 1"),
              std::string::npos);
  }
  // Raising the solving budget does not discard a still-valid cached answer.
  EXPECT_TRUE(Result.getJavaType(V, Context).isUnknown());
  EXPECT_NE(statistics(FAM, F).find("final type hits: 1"), std::string::npos);
  EXPECT_NE(statistics(FAM, F).find("current final type entries: 1"),
            std::string::npos);
  Result.clear();
  EXPECT_EQ(Result.getJavaType(V, Context).Klass, 22U);
  // An already-computed precise answer needs no new solving budget either.
  {
    ScopedQueryOption<unsigned> Budget("jeandle-max-facts-join-blocks", 0);
    EXPECT_EQ(Result.getJavaType(V, Context).Klass, 22U);
  }
  EXPECT_NE(statistics(FAM, F).find("final type hits: 2"), std::string::npos);
  EXPECT_NE(statistics(FAM, F).find("current final type entries: 1"),
            std::string::npos);
}

TEST_F(JavaTypeQueryTest, FinalPhiResultsReuseOneEntryAcrossBudgets) {
  Function *F = parse(R"(
    define void @test(ptr "java-klass"="22" %obj) {
    entry:
      br label %merge
    merge:
      %p = phi ptr [ %obj, %entry ]
      ret void
    }
  )");
  ASSERT_NE(F, nullptr);
  FunctionAnalysisManager FAM;
  PassBuilder PB;
  PB.registerFunctionAnalyses(FAM);
  auto &Result = FAM.getResult<JavaTypeAnalysis>(*F);
  BasicBlock *Merge = block(*F, "merge");
  {
    ScopedQueryOption<unsigned> Budget("jeandle-max-facts-join-blocks", 0);
    auto &DT = FAM.getResult<DominatorTreeAnalysis>(*F);
    auto &LVI = FAM.getResult<LazyValueAnalysis>(*F);
    LVINullEdgeOracle Oracle{LVI};
    EXPECT_EQ(Result.getJavaType(&Merge->front(), Merge->getTerminator()),
              jeandle::getJavaType(&Merge->front(), &DT,
                                   Merge->getTerminator(), Oracle));
    EXPECT_NE(statistics(FAM, F).find("current final type entries: 1"),
              std::string::npos);
  }
  EXPECT_EQ(Result.getJavaType(&Merge->front(), Merge->getTerminator()).Klass, 22U);
  EXPECT_NE(statistics(FAM, F).find("final type hits: 1"), std::string::npos);
  EXPECT_NE(statistics(FAM, F).find("current final type entries: 1"),
            std::string::npos);
}

TEST_F(JavaTypeQueryTest, DisabledCacheBypassesFinalTypes) {
  Function *F = parse(IR);
  ASSERT_NE(F, nullptr);
  FunctionAnalysisManager FAM;
  PassBuilder PB;
  PB.registerFunctionAnalyses(FAM);
  auto &Result = FAM.getResult<JavaTypeAnalysis>(*F);
  Value *V = F->getArg(0);
  Instruction *Context = block(*F, "hit")->getTerminator();
  EXPECT_EQ(Result.getJavaType(V, Context).Klass, 22U);
  {
    ScopedQueryOption<bool> Disable("jeandle-disable-java-type-cache", true);
    EXPECT_EQ(Result.getJavaType(V, Context).Klass, 22U);
    EXPECT_EQ(Result.getJavaType(V, block(*F, "tail")->getTerminator()).Klass, 22U);
  }
  EXPECT_NE(statistics(FAM, F).find("final type hits: 0"), std::string::npos);
  EXPECT_NE(statistics(FAM, F).find("current final type entries: 1"),
            std::string::npos);
}

TEST_F(JavaTypeQueryTest, DisabledCacheUsesOriginalAfterAttributeChange) {
  Function *F = parse(R"(
    define void @test(ptr "java-klass"="22" %obj) {
      ret void
    }
  )");
  ASSERT_NE(F, nullptr);
  FunctionAnalysisManager FAM;
  PassBuilder PB;
  PB.registerFunctionAnalyses(FAM);
  auto &Result = FAM.getResult<JavaTypeAnalysis>(*F);
  Value *V = F->getArg(0);
  Instruction *Context = F->getEntryBlock().getTerminator();
  EXPECT_EQ(Result.getJavaType(V, Context).Klass, 22U);

  // Deliberately leave the cache stale to prove bypass cannot consult it.
  // No cached query is made until clear() below.
  F->removeParamAttr(0, "java-klass");
  F->addParamAttr(0, Attribute::get(C, "java-klass", "33"));
  {
    ScopedQueryOption<bool> Disable("jeandle-disable-java-type-cache", true);
    EXPECT_EQ(Result.getJavaType(V, Context),
              jeandle::getJavaType(V, nullptr, Context, nullptr));
    EXPECT_EQ(Result.getJavaType(V).Klass, 33U);
  }
  EXPECT_NE(statistics(FAM, F).find("final type hits: 0"), std::string::npos);
  EXPECT_NE(statistics(FAM, F).find("current final type entries: 1"),
            std::string::npos);
  Result.clear();
  EXPECT_EQ(Result.getJavaType(V, Context).Klass, 33U);
}

TEST_F(JavaTypeQueryTest, CachedAndOriginalQueriesAgreeAcrossBudgets) {
  Function *F = parse(IR);
  ASSERT_NE(F, nullptr);
  DominatorTree DT(*F);
  Value *V = F->getArg(0);
  for (unsigned Limit : {0U, 1U, 128U}) {
    ScopedQueryOption<unsigned> Budget("jeandle-max-facts-join-blocks", Limit);
    for (BasicBlock &BB : *F) {
      SCOPED_TRACE(BB.getName().str() + " budget=" + std::to_string(Limit));
      JavaTypeCache Cache(F, JavaTypeCache::Mode::StableOracleEpoch);
      Cache.setStatsEnabled(true);
      Instruction *Context = BB.getTerminator();
      EXPECT_EQ(getCachedJavaType(V, &DT, Context, nullptr, Cache),
                jeandle::getJavaType(V, &DT, Context, nullptr));
    }
  }
}

TEST_F(JavaTypeQueryTest, SelectiveBaseDeletionMatchesScanBaseline) {
  Function *F = parse(R"(
    define void @test(ptr "java-klass"="22" %a,
                      ptr "java-klass"="33" %b,
                      ptr "java-klass"="44" %independent, i1 %c) {
      %first = select i1 %c, ptr %a, ptr %a
      %second = select i1 %c, ptr %first, ptr %first
      ret void
    }
  )");
  ASSERT_NE(F, nullptr);
  DominatorTree DT(*F);
  JavaTypeCache ScanCache(F, JavaTypeCache::Mode::StableOracleEpoch);
  ScanCache.setStatsEnabled(true);
  JavaTypeCache KeyCache(F, JavaTypeCache::Mode::StableOracleEpoch);
  KeyCache.setStatsEnabled(true);
  auto *First = cast<SelectInst>(&F->getEntryBlock().front());
  auto *Second = cast<SelectInst>(First->getNextNode());
  Value *A = F->getArg(0);
  Value *B = F->getArg(1);
  Value *Independent = F->getArg(2);

  auto Populate = [&](JavaTypeCache &Cache) {
    EXPECT_EQ(getCachedJavaType(Second, &DT, nullptr, nullptr, Cache).Klass,
              22U);
    EXPECT_EQ(getCachedJavaType(B, &DT, nullptr, nullptr, Cache).Klass,
              33U);
    EXPECT_EQ(
        getCachedJavaType(Independent, &DT, nullptr, nullptr, Cache).Klass,
        44U);
    EXPECT_EQ(Cache.baseSize(), 5U);
  };
  Populate(ScanCache);
  Populate(KeyCache);

  JavaTypeCacheInvalidationInfo Scanned = ScanCache.invalidate(
      {A}, false, JavaTypeBaseInvalidationMode::Scan);
  JavaTypeCacheInvalidationInfo Keyed = KeyCache.invalidate(
      {A}, false, JavaTypeBaseInvalidationMode::SelectiveKeys);

  EXPECT_EQ(Scanned.BaseRemoved, 3U);
  EXPECT_EQ(Keyed.BaseRemoved, 3U);
  EXPECT_EQ(Scanned.BaseRemoved, Keyed.BaseRemoved);
  EXPECT_EQ(Scanned.FactsRemoved, Keyed.FactsRemoved);
  EXPECT_EQ(Scanned.FinalRemoved, Keyed.FinalRemoved);
  EXPECT_EQ(Scanned.ValuesVisited, Keyed.ValuesVisited);
  EXPECT_EQ(Scanned.BaseSlotsScanned, 5U);
  EXPECT_EQ(Keyed.BaseSlotsScanned, 0U);
  EXPECT_EQ(ScanCache.baseSize(), 2U);
  EXPECT_EQ(KeyCache.baseSize(), 2U);

  F->removeParamAttr(0, "java-klass");
  F->addParamAttr(0, Attribute::get(C, "java-klass", "33"));
  JavaType Expected = jeandle::getJavaType(Second, &DT, nullptr, nullptr);
  EXPECT_EQ(getCachedJavaType(Second, &DT, nullptr, nullptr, ScanCache),
            Expected);
  EXPECT_EQ(getCachedJavaType(Second, &DT, nullptr, nullptr, KeyCache),
            Expected);
}

TEST_F(JavaTypeQueryTest, TypeFactCanBecomeKnownAndWeakensAfterRepeatedEdits) {
  Function *F = parse(R"(
    define void @test(ptr %a, ptr "java-klass"="33" %b, i1 %c) {
      %derived = select i1 %c, ptr %a, ptr %b
      ret void
    }
  )");
  ASSERT_NE(F, nullptr);
  DominatorTree DT(*F);
  JavaTypeCache Cache(F, JavaTypeCache::Mode::StableOracleEpoch);
  Cache.setStatsEnabled(true);
  Value *A = F->getArg(0);
  Value *B = F->getArg(1);
  Value *Derived = &F->getEntryBlock().front();
  Instruction *Context = F->getEntryBlock().getTerminator();

  EXPECT_TRUE(getCachedJavaType(Derived, &DT, Context, nullptr, Cache)
                  .isUnknown());
  EXPECT_EQ(getCachedJavaType(B, &DT, Context, nullptr, Cache).Klass,
            33U);

  Cache.invalidate({A});
  F->addParamAttr(0, Attribute::get(C, "java-klass", "22"));
  EXPECT_EQ(getCachedJavaType(B, &DT, Context, nullptr, Cache).Klass,
            33U);
  EXPECT_EQ(Cache.Final.getStats().Hits, 0U);
  EXPECT_EQ(
      getCachedJavaType(Derived, &DT, Context, nullptr, Cache).Klass, 1U);

  Cache.invalidate({A});
  F->removeParamAttr(0, "java-klass");
  F->addParamAttr(0, Attribute::get(C, "java-klass", "44"));
  EXPECT_EQ(
      getCachedJavaType(Derived, &DT, Context, nullptr, Cache).Klass, 1U);

  Cache.invalidate({A});
  F->removeParamAttr(0, "java-klass");
  EXPECT_TRUE(getCachedJavaType(Derived, &DT, Context, nullptr, Cache)
                  .isUnknown());
  EXPECT_EQ(getCachedJavaType(Derived, &DT, Context, nullptr, Cache),
            jeandle::getJavaType(Derived, &DT, Context, nullptr));
}

TEST_F(JavaTypeQueryTest, RepeatedTypeFactMutationRoundTripsThroughAValue) {
  Function *F = parse(R"(
    define void @test(ptr "java-klass"="22" %a, i1 %condition) {
      %derived = select i1 %condition, ptr %a, ptr %a
      ret void
    }
  )");
  ASSERT_NE(F, nullptr);
  DominatorTree DT(*F);
  JavaTypeCache Cache(F, JavaTypeCache::Mode::StableOracleEpoch);
  Cache.setStatsEnabled(true);
  Value *A = F->getArg(0);
  Value *Derived = &F->getEntryBlock().front();

  const unsigned Expected[] = {22U, 33U, 44U, 22U, 33U};
  for (unsigned I = 0; I != 5; ++I) {
    EXPECT_EQ(getCachedJavaType(Derived, &DT, nullptr, nullptr, Cache).Klass,
              Expected[I]);
    if (I + 1 == 5)
      break;
    Cache.invalidate({A});
    F->removeParamAttr(0, "java-klass");
    F->addParamAttr(
        0, Attribute::get(C, "java-klass", std::to_string(Expected[I + 1])));
  }
  EXPECT_EQ(getCachedJavaType(Derived, &DT, nullptr, nullptr, Cache),
            jeandle::getJavaType(Derived, &DT, nullptr, nullptr));
}

TEST_F(JavaTypeQueryTest, CallAndLoadTypeFactsAreInvalidatedBeforeEdits) {
  Function *F = parse(R"(
    declare ptr @producer(i32)
    define void @test(ptr %address, i32 %value) {
      %call = call ptr @producer(i32 %value)
      %load = load ptr, ptr %address
      ret void
    }
  )");
  ASSERT_NE(F, nullptr);
  DominatorTree DT(*F);
  JavaTypeCache Cache(F, JavaTypeCache::Mode::StableOracleEpoch);
  Cache.setStatsEnabled(true);
  auto *Call = cast<CallInst>(&F->getEntryBlock().front());
  auto *Load = cast<LoadInst>(Call->getNextNode());
  Instruction *Context = F->getEntryBlock().getTerminator();

  EXPECT_TRUE(
      getCachedJavaType(Call, &DT, Context, nullptr, Cache).isUnknown());
  EXPECT_TRUE(
      getCachedJavaType(Load, &DT, Context, nullptr, Cache).isUnknown());

  Cache.invalidate({Call});
  Call->addRetAttr(Attribute::get(C, "java-klass", "22"));
  Call->addRetAttr(Attribute::get(C, "java-klass-exact"));
  JavaType CallType =
      getCachedJavaType(Call, &DT, Context, nullptr, Cache);
  EXPECT_EQ(CallType.Klass, 22U);
  EXPECT_TRUE(CallType.Exact);

  Cache.invalidate({Load});
  Metadata *Klass =
      ConstantAsMetadata::get(ConstantInt::get(Type::getInt64Ty(C), 44));
  Load->setMetadata("java-klass", MDNode::get(C, {Klass}));
  Load->setMetadata("java-klass-exact", MDNode::get(C, {}));
  JavaType LoadType =
      getCachedJavaType(Load, &DT, Context, nullptr, Cache);
  EXPECT_EQ(LoadType.Klass, 44U);
  EXPECT_TRUE(LoadType.Exact);
  EXPECT_EQ(LoadType, jeandle::getJavaType(Load, &DT, Context, nullptr));
}

TEST_F(JavaTypeQueryTest, ParentQueryReusesAndInvalidatesCachedChild) {
  Function *F = parse(R"(
    define void @test(ptr "java-klass"="22" %a,
                      ptr "java-klass"="33" %b, i1 %c) {
      %child = select i1 %c, ptr %a, ptr %b
      %parent = select i1 %c, ptr %child, ptr %child
      ret void
    }
  )");
  ASSERT_NE(F, nullptr);
  DominatorTree DT(*F);
  JavaTypeCache Cache(F, JavaTypeCache::Mode::StableOracleEpoch);
  Cache.setStatsEnabled(true);
  Value *A = F->getArg(0);
  auto *Child = cast<SelectInst>(&F->getEntryBlock().front());
  auto *Parent = cast<SelectInst>(Child->getNextNode());

  EXPECT_EQ(getCachedJavaType(Child, &DT, nullptr, nullptr, Cache).Klass,
            1U);
  EXPECT_EQ(getCachedJavaType(Parent, &DT, nullptr, nullptr, Cache).Klass,
            1U);

  JavaTypeCacheInvalidationInfo Invalidated = Cache.invalidate({A});
  EXPECT_EQ(Invalidated.BaseRemoved, 3U);
  EXPECT_EQ(Cache.baseSize(), 1U);
  F->removeParamAttr(0, "java-klass");
  F->addParamAttr(0, Attribute::get(C, "java-klass", "33"));
  EXPECT_EQ(getCachedJavaType(Parent, &DT, nullptr, nullptr, Cache).Klass,
            33U);
  EXPECT_EQ(getCachedJavaType(Parent, &DT, nullptr, nullptr, Cache),
            jeandle::getJavaType(Parent, &DT, nullptr, nullptr));
}

TEST_F(JavaTypeQueryTest,
       DeleteBlockDropsCachedLeavesAndRetainsIndependentValue) {
  Function *F = parse(R"(
    define void @test(ptr "java-klass"="22" %obj, ptr %address, i1 %c) {
    entry:
      br i1 %c, label %dead, label %live
    dead:
      %leaf = load ptr, ptr %address
      br label %exit
    live:
      br label %exit
    exit:
      ret void
    }
  )");
  ASSERT_NE(F, nullptr);
  DominatorTree DT(*F);
  JavaTypeCache Cache(F, JavaTypeCache::Mode::StableOracleEpoch);
  Cache.setStatsEnabled(true);
  BasicBlock *Entry = &F->getEntryBlock();
  BasicBlock *DeadBlock = block(*F, "dead");
  BasicBlock *LiveBlock = block(*F, "live");
  auto *Leaf = cast<LoadInst>(&DeadBlock->front());
  Instruction *DeadBranch = DeadBlock->getTerminator();
  Instruction *EntryBranch = Entry->getTerminator();
  Value *Obj = F->getArg(0);

  EXPECT_TRUE(getCachedJavaType(Leaf, &DT, DeadBranch, nullptr, Cache)
                  .isUnknown());
  EXPECT_EQ(getCachedJavaType(Obj, &DT, DeadBranch, nullptr, Cache).Klass,
            22U);

  JavaTypeCacheInvalidationInfo Invalidated =
      Cache.invalidate({Leaf, EntryBranch}, true);
  EXPECT_FALSE(Invalidated.FullClear);
  EXPECT_EQ(Invalidated.BaseRemoved, 1U);

  BranchInst::Create(LiveBlock, EntryBranch->getIterator());
  EntryBranch->eraseFromParent();
  Leaf->eraseFromParent();
  DeadBranch->eraseFromParent();
  DeadBlock->eraseFromParent();
  DT.recalculate(*F);
  EXPECT_FALSE(verifyFunction(*F, &errs()));

  EXPECT_EQ(getCachedJavaType(Obj, &DT, nullptr, nullptr, Cache).Klass,
            22U);
  EXPECT_GT(Cache.Base.getStats().Hits, 0U);
}

TEST_F(JavaTypeQueryTest, BatchedDiamondInvalidationMatchesSequential) {
  Function *F = parse(R"(
    define void @test(ptr "java-klass"="22" %a,
                      ptr "java-klass"="33" %b,
                      ptr "java-klass"="44" %independent, i1 %c) {
      %x = select i1 %c, ptr %a, ptr %b
      %y = select i1 %c, ptr %b, ptr %a
      %z = select i1 %c, ptr %x, ptr %y
      ret void
    }
  )");
  ASSERT_NE(F, nullptr);
  DominatorTree DT(*F);
  JavaTypeCache Batched(F, JavaTypeCache::Mode::StableOracleEpoch);
  Batched.setStatsEnabled(true);
  JavaTypeCache Sequential(F, JavaTypeCache::Mode::StableOracleEpoch);
  Sequential.setStatsEnabled(true);
  auto *X = cast<SelectInst>(&F->getEntryBlock().front());
  auto *Y = cast<SelectInst>(X->getNextNode());
  auto *Z = cast<SelectInst>(Y->getNextNode());
  Value *Independent = F->getArg(2);
  Instruction *Context = F->getEntryBlock().getTerminator();

  EXPECT_EQ(getCachedJavaType(Z, &DT, Context, nullptr, Batched).Klass,
            1U);
  EXPECT_EQ(getCachedJavaType(Independent, &DT, Context, nullptr, Batched)
                .Klass,
            44U);
  EXPECT_EQ(getCachedJavaType(Z, &DT, Context, nullptr, Sequential).Klass,
            1U);
  EXPECT_EQ(
      getCachedJavaType(Independent, &DT, Context, nullptr, Sequential)
          .Klass,
      44U);

  Batched.invalidate({X, Y});
  Sequential.invalidate({X});
  Sequential.invalidate({Y});
  X->setOperand(2, F->getArg(0));
  Y->setOperand(1, F->getArg(0));

  JavaType Expected = jeandle::getJavaType(Z, &DT, Context, nullptr);
  EXPECT_EQ(getCachedJavaType(Z, &DT, Context, nullptr, Batched),
            Expected);
  EXPECT_EQ(getCachedJavaType(Z, &DT, Context, nullptr, Sequential),
            Expected);
  EXPECT_EQ(getCachedJavaType(Independent, &DT, Context, nullptr, Batched)
                .Klass,
            44U);
  EXPECT_EQ(Batched.Final.getStats().Hits, 0U);
}

TEST_F(JavaTypeQueryTest, InvalidationAtValueLimitDoesNotClear) {
  Function *F = parse(R"(
    define void @test(ptr "java-klass"="22" %obj, i1 %condition) {
      ret void
    }
  )");
  ASSERT_NE(F, nullptr);
  Instruction *Ret = F->getEntryBlock().getTerminator();
  for (unsigned I = 0; I != 4095; ++I)
    SelectInst::Create(F->getArg(1), F->getArg(0), F->getArg(0), "derived",
                       Ret->getIterator());
  JavaTypeCache Cache(F, JavaTypeCache::Mode::StableOracleEpoch);
  Cache.setStatsEnabled(true);
  EXPECT_EQ(
      getCachedJavaType(F->getArg(0), nullptr, nullptr, nullptr, Cache)
          .Klass,
      22U);
  JavaTypeCacheInvalidationInfo Invalidated = Cache.invalidate({F->getArg(1)});
  EXPECT_FALSE(Invalidated.FullClear);
  EXPECT_EQ(Invalidated.ValuesVisited, 4096U);
}

TEST_F(JavaTypeQueryTest, InvalidationJustBelowValueLimitDoesNotClear) {
  Function *F = parse(R"(
    define void @test(ptr "java-klass"="22" %obj, i1 %condition) {
      ret void
    }
  )");
  ASSERT_NE(F, nullptr);
  Instruction *Ret = F->getEntryBlock().getTerminator();
  for (unsigned I = 0; I != 4094; ++I)
    SelectInst::Create(F->getArg(1), F->getArg(0), F->getArg(0), "derived",
                       Ret->getIterator());
  JavaTypeCache Cache(F, JavaTypeCache::Mode::StableOracleEpoch);
  Cache.setStatsEnabled(true);
  EXPECT_EQ(
      getCachedJavaType(F->getArg(0), nullptr, nullptr, nullptr, Cache)
          .Klass,
      22U);
  JavaTypeCacheInvalidationInfo Invalidated = Cache.invalidate({F->getArg(1)});
  EXPECT_FALSE(Invalidated.FullClear);
  EXPECT_EQ(Invalidated.ValuesVisited, 4095U);
}

TEST_F(JavaTypeQueryTest, InvalidationUseThresholdUsesInclusiveBoundary) {
  for (unsigned Uses : {16383U, 16384U, 16385U}) {
    SCOPED_TRACE(testing::Message() << "uses=" << Uses);
    Function *F = parse(R"(
      declare void @sink(...)
      define void @test(ptr "java-klass"="22" %obj, i1 %condition) {
        ret void
      }
    )");
    ASSERT_NE(F, nullptr);
    Instruction *Ret = F->getEntryBlock().getTerminator();
    Function *Sink = F->getParent()->getFunction("sink");
    unsigned Remaining = Uses;
    while (Remaining != 0) {
      unsigned Operands = std::min(Remaining, 16U);
      SmallVector<Value *, 16> Args(Operands, F->getArg(1));
      CallInst::Create(Sink, Args, "", Ret->getIterator());
      Remaining -= Operands;
    }

    JavaTypeCache Cache(F, JavaTypeCache::Mode::StableOracleEpoch);

    Cache.setStatsEnabled(true);
    EXPECT_EQ(
        getCachedJavaType(F->getArg(0), nullptr, nullptr, nullptr, Cache)
            .Klass,
        22U);
    JavaTypeCacheInvalidationInfo Invalidated = Cache.invalidate({F->getArg(1)});
    EXPECT_EQ(Invalidated.UsesVisited, Uses);
    EXPECT_EQ(Invalidated.FullClear, Uses > 16384U);
  }
}

TEST_F(JavaTypeQueryTest, InvalidationUseLimitFallsBackToClear) {
  Function *F = parse(R"(
    declare void @sink(i1, i1, i1, i1, i1)
    define void @test(ptr "java-klass"="22" %obj, i1 %condition) {
      ret void
    }
  )");
  ASSERT_NE(F, nullptr);
  Instruction *Ret = F->getEntryBlock().getTerminator();
  for (unsigned I = 0; I != 4095; ++I)
    CallInst::Create(
        F->getParent()->getFunction("sink"),
        {F->getArg(1), F->getArg(1), F->getArg(1), F->getArg(1), F->getArg(1)},
        "sink", Ret->getIterator());
  JavaTypeCache Cache(F, JavaTypeCache::Mode::StableOracleEpoch);
  Cache.setStatsEnabled(true);
  EXPECT_EQ(
      getCachedJavaType(F->getArg(0), nullptr, nullptr, nullptr, Cache)
          .Klass,
      22U);
  JavaTypeCacheInvalidationInfo Invalidated = Cache.invalidate({F->getArg(1)});
  EXPECT_TRUE(Invalidated.FullClear);
  EXPECT_EQ(Cache.baseSize(), 0U);
}

TEST_F(JavaTypeQueryTest, ActualLVIObservesDereferenceMutationAfterClear) {
  Function *F = parse(R"(
    define void @test(ptr %obj, i1 %condition) {
    entry:
      br i1 %condition, label %next, label %other
    next:
      ret void
    other:
      ret void
    }
  )");
  ASSERT_NE(F, nullptr);
  FunctionAnalysisManager FAM;
  PassBuilder PB;
  PB.registerFunctionAnalyses(FAM);
  LazyValueInfo &LVI = FAM.getResult<LazyValueAnalysis>(*F);
  LVINullEdgeOracle Oracle{LVI};
  Value *Obj = F->getArg(0);
  BasicBlock *Entry = &F->getEntryBlock();
  BasicBlock *Next = block(*F, "next");
  auto *Null = ConstantPointerNull::get(cast<PointerType>(Obj->getType()));

  Constant *Before =
      LVI.getPredicateOnEdge(ICmpInst::ICMP_EQ, Obj, Null, Entry, Next);
  EXPECT_EQ(Before, nullptr);
  auto *Store = new StoreInst(ConstantInt::get(Type::getInt8Ty(C), 0), Obj,
                              Entry->getTerminator()->getIterator());
  LVI.clear();
  Constant *After =
      LVI.getPredicateOnEdge(ICmpInst::ICMP_EQ, Obj, Null, Entry, Next);
  EXPECT_TRUE(After && After->isZeroValue());
  EXPECT_FALSE(Oracle(Obj, Entry, Next));
  Store->eraseFromParent();
}

TEST_F(JavaTypeQueryTest, DeadNarrowCFFLoadIsInvalidatedBeforeDeletion) {
  Function *F = parse(R"(
    @oop_handle_Root_0 = external global ptr addrspace(1)

    define void @test() gc "hotspotgc" {
    entry:
      %base = load ptr addrspace(1), ptr @oop_handle_Root_0
      %addr = getelementptr i8, ptr addrspace(1) %base, i64 16
      %dead = load ptr addrspace(3), ptr addrspace(1) %addr
      ret void
    }

    !java-method-compilation = !{}
  )");
  ASSERT_NE(F, nullptr);

  VMCallbacks CB = *getVMCallbacks();
  CB.GetConstantField = [](int, int) -> ConstantFieldResult {
    return {12 /* T_OBJECT */, 1};
  };
  CB.GetOopHandleName = [](int) -> std::string { return "oop_handle_Child_1"; };
  registerVMCallbacks(CB);

  PassBuilder PB;
  FunctionAnalysisManager FAM;
  PB.registerFunctionAnalyses(FAM);
  JavaTypeAnalysisResult &JavaTypes = FAM.getResult<JavaTypeAnalysis>(*F);

  LoadInst *Dead = nullptr;
  for (Instruction &I : F->getEntryBlock())
    if (auto *LI = dyn_cast<LoadInst>(&I))
      if (LI->getType()->isPointerTy() &&
          LI->getType()->getPointerAddressSpace() == 3)
        Dead = LI;
  ASSERT_NE(Dead, nullptr);

  // Populate the same base key that CFF is about to erase. A fresh query for
  // an opaque load is complete and therefore cacheable.
  EXPECT_TRUE(JavaTypes.getJavaType(Dead).isUnknown());
  EXPECT_EQ(
      FAM.getResult<JavaTypeStatsAnalysis>(*F).getStats().CurrentBaseEntries,
      1U);

  PreservedAnalyses PA = ConstantFieldFolding().run(*F, FAM);
  EXPECT_FALSE(PA.areAllPreserved());

  // CFF normally causes FAM to destroy the result at the pass boundary. Check
  // the cache state here, before that cleanup, without dereferencing Dead.
  const JavaTypeQueryStats &After =
      FAM.getResult<JavaTypeStatsAnalysis>(*F).getStats();
  EXPECT_GE(After.Invalidations, 1U);
  EXPECT_GE(After.BaseRemoved, 1U);
  EXPECT_EQ(After.CurrentBaseEntries, 0U);
}

TEST_F(JavaTypeQueryTest, CopySpecializationWithoutCopiesPreservesCachedAnalysis) {
  Function *F = parse(R"(
    define void @test(ptr "java-klass"="22" %obj) #0 {
      ret void
    }
    attributes #0 = { "java-method"="0" }
  )");
  ASSERT_NE(F, nullptr);
  FunctionAnalysisManager FAM;
  PassBuilder PB;
  PB.registerFunctionAnalyses(FAM);
  auto *Analysis = &FAM.getResult<JavaTypeAnalysis>(*F);
  Instruction *At = F->getEntryBlock().getTerminator();
  EXPECT_EQ(Analysis->getJavaType(F->getArg(0), At), JavaType(22, false));

  PreservedAnalyses PA = CopySpecialization().run(*F, FAM);
  EXPECT_TRUE(PA.areAllPreserved());
  EXPECT_EQ(FAM.getResult<JavaTypeStatsAnalysis>(*F).getStats().Queries, 1U);
  FAM.invalidate(*F, PA);
  EXPECT_EQ(FAM.getCachedResult<JavaTypeAnalysis>(*F), Analysis);
  EXPECT_EQ(Analysis->getJavaType(F->getArg(0), At), JavaType(22, false));
  EXPECT_EQ(FAM.getResult<JavaTypeStatsAnalysis>(*F).getStats().FinalHits, 1U);
}

TEST_F(JavaTypeQueryTest, CopySpecializationSharesQueriesBeforeBulkCloneExpansion) {
  Function *F = parse(R"(
    declare void @jeandle.copy(ptr addrspace(1), i64, ptr addrspace(1),
                               i64, i64, ptr, ptr, i64, i64)
    define hotspotcc void @jeandle.clone_payload(
        ptr addrspace(1) %src, i64 %src_offset, ptr addrspace(1) %dest,
        i64 %dest_offset, i64 %length, i1 %instance) {
      ret void
    }
    define void @test(ptr addrspace(1) "java-klass"="22" %src,
                      ptr addrspace(1) %dest) #0 gc "hotspotgc" {
      call void @jeandle.copy(ptr addrspace(1) %src, i64 8,
          ptr addrspace(1) %dest, i64 8, i64 1, ptr null, ptr null,
          i64 8, i64 8) #1
      call void @jeandle.copy(ptr addrspace(1) %src, i64 8,
          ptr addrspace(1) %dest, i64 8, i64 1, ptr null, ptr null,
          i64 8, i64 8) #1
      ret void
    }
    attributes #0 = { "java-method"="0" }
    attributes #1 = { "jeandle.copy.kind"="clone-instance" }
  )");
  ASSERT_NE(F, nullptr);
  VMCallbacks CB = *getVMCallbacks();
  CB.GetCloneInstanceInfo = [](uintptr_t Klass, bool Exact) {
    EXPECT_EQ(Klass, 22U);
    EXPECT_FALSE(Exact);
    return CloneInstanceInfoResult{
        static_cast<int>(CloneInstanceInfoStatus::NotApplicable), -1, {}};
  };
  registerVMCallbacks(CB);
  FunctionAnalysisManager FAM;
  PassBuilder PB;
  PB.registerFunctionAnalyses(FAM);

  PreservedAnalyses PA = CopySpecialization().run(*F, FAM);
  EXPECT_FALSE(PA.areAllPreserved());
  const auto &Stats = FAM.getResult<JavaTypeStatsAnalysis>(*F).getStats();
  EXPECT_EQ(Stats.Queries, 2U);
  EXPECT_EQ(Stats.FinalMisses, 1U);
  EXPECT_EQ(Stats.FinalHits, 1U);
  unsigned Expanded = 0;
  for (Instruction &I : F->getEntryBlock())
    if (auto *Call = dyn_cast<CallInst>(&I)) {
      ASSERT_NE(Call->getCalledFunction(), nullptr);
      EXPECT_EQ(Call->getCalledFunction()->getName(), "jeandle.clone_payload");
      ++Expanded;
    }
  EXPECT_EQ(Expanded, 2U);
  EXPECT_FALSE(verifyFunction(*F, &errs()));

  // Admission declined scalarization, but bulk expansion still changed IR.
  // The pass performs no queries after those rewrites; FAM drops the result.
  FAM.invalidate(*F, PA);
  EXPECT_EQ(FAM.getCachedResult<JavaTypeAnalysis>(*F), nullptr);
  EXPECT_EQ(FAM.getCachedResult<DominatorTreeAnalysis>(*F), nullptr);
  EXPECT_EQ(FAM.getCachedResult<LazyValueAnalysis>(*F), nullptr);
  auto &Analysis = FAM.getResult<JavaTypeAnalysis>(*F);
  Instruction *At = F->getEntryBlock().getTerminator();
  auto &DT = FAM.getResult<DominatorTreeAnalysis>(*F);
  auto &LVI = FAM.getResult<LazyValueAnalysis>(*F);
  EXPECT_EQ(Analysis.getJavaType(F->getArg(0), At),
            getJavaType(F->getArg(0), &DT, At, LVINullEdgeOracle{LVI}));
  EXPECT_EQ(Stats.FinalMisses, 2U);
}

TEST_F(JavaTypeQueryTest, CopySpecializationInvalidatesAfterCloneScalarization) {
  Function *F = parse(R"(
    declare void @jeandle.copy(ptr addrspace(1), i64, ptr addrspace(1),
                               i64, i64, ptr, ptr, i64, i64)
    define void @test(
        ptr addrspace(1) "java-klass"="22" "java-klass-exact" %src,
        ptr addrspace(1) %dest) #0 gc "hotspotgc" {
      call void @jeandle.copy(ptr addrspace(1) %src, i64 8,
          ptr addrspace(1) %dest, i64 8, i64 1, ptr null, ptr null,
          i64 8, i64 8) #1
      ret void
    }
    attributes #0 = { "java-method"="0" }
    attributes #1 = { "jeandle.copy.kind"="clone-instance" }
  )");
  ASSERT_NE(F, nullptr);
  VMCallbacks CB = *getVMCallbacks();
  CB.GetCloneInstanceInfo = [](uintptr_t Klass, bool Exact) {
    EXPECT_EQ(Klass, 22U);
    EXPECT_TRUE(Exact);
    return CloneInstanceInfoResult{
        static_cast<int>(CloneInstanceInfoStatus::Ready), 1,
        {{12, static_cast<int>(JBasicType::Int)}}};
  };
  registerVMCallbacks(CB);
  FunctionAnalysisManager FAM;
  PassBuilder PB;
  PB.registerFunctionAnalyses(FAM);

  PreservedAnalyses PA = CopySpecialization().run(*F, FAM);
  EXPECT_FALSE(PA.areAllPreserved());
  const auto &Stats = FAM.getResult<JavaTypeStatsAnalysis>(*F).getStats();
  EXPECT_EQ(Stats.Queries, 1U);
  EXPECT_EQ(Stats.FinalMisses, 1U);
  unsigned Loads = 0;
  unsigned Stores = 0;
  for (Instruction &I : F->getEntryBlock()) {
    EXPECT_FALSE(isa<CallInst>(I));
    Loads += isa<LoadInst>(I);
    Stores += isa<StoreInst>(I);
  }
  EXPECT_EQ(Loads, 1U);
  EXPECT_EQ(Stores, 1U);
  EXPECT_FALSE(verifyFunction(*F, &errs()));

  FAM.invalidate(*F, PA);
  EXPECT_EQ(FAM.getCachedResult<JavaTypeAnalysis>(*F), nullptr);
  EXPECT_EQ(FAM.getCachedResult<DominatorTreeAnalysis>(*F), nullptr);
  EXPECT_EQ(FAM.getCachedResult<LazyValueAnalysis>(*F), nullptr);
  auto &Analysis = FAM.getResult<JavaTypeAnalysis>(*F);
  Instruction *At = F->getEntryBlock().getTerminator();
  auto &DT = FAM.getResult<DominatorTreeAnalysis>(*F);
  auto &LVI = FAM.getResult<LazyValueAnalysis>(*F);
  JavaType Actual = Analysis.getJavaType(F->getArg(0), At);
  EXPECT_EQ(Actual, JavaType(22, true));
  EXPECT_EQ(Actual,
            getJavaType(F->getArg(0), &DT, At, LVINullEdgeOracle{LVI}));
  EXPECT_EQ(Stats.FinalMisses, 2U);
}

TEST_F(JavaTypeQueryTest, InvalidateBeforeRAUWAndDeletion) {
  Function *F = parse(R"(
    define void @test(ptr "java-klass"="22" %a,
                      ptr "java-klass"="33" %b, i1 %c) {
      %old = select i1 %c, ptr %a, ptr %a
      %derived = select i1 %c, ptr %old, ptr %old
      ret void
    }
  )");
  ASSERT_NE(F, nullptr);
  DominatorTree DT(*F);
  JavaTypeCache Cache(F, JavaTypeCache::Mode::StableOracleEpoch);
  Cache.setStatsEnabled(true);
  Instruction *Old = &F->getEntryBlock().front();
  Instruction *Derived = Old->getNextNode();
  Instruction *Context = F->getEntryBlock().getTerminator();
  EXPECT_EQ(getCachedJavaType(Old, &DT, Context, nullptr, Cache).Klass, 22U);
  EXPECT_EQ(getCachedJavaType(Derived, &DT, Context, nullptr, Cache).Klass,
            22U);
  Cache.invalidate({Old});
  Old->replaceAllUsesWith(F->getArg(1));
  Old->eraseFromParent();
  EXPECT_FALSE(verifyFunction(*F, &errs()));
  EXPECT_EQ(getCachedJavaType(Derived, &DT, Context, nullptr, Cache).Klass,
            33U);
  EXPECT_EQ(getCachedJavaType(F->getArg(0), &DT, nullptr, nullptr, Cache).Klass,
            22U);
  EXPECT_GT(Cache.Base.getStats().Hits, 0U);
}

TEST_F(JavaTypeQueryTest, InvalidateBeforeDeletionPreventsKeyReuse) {
  Function *F = parse(R"(
    define void @test(ptr "java-klass"="22" %a,
                      ptr "java-klass"="33" %b, i1 %c) {
      %old = select i1 %c, ptr %a, ptr %a
      ret void
    }
  )");
  ASSERT_NE(F, nullptr);
  JavaTypeCache Cache(F, JavaTypeCache::Mode::StableOracleEpoch);
  Cache.setStatsEnabled(true);
  auto *Old = cast<SelectInst>(&F->getEntryBlock().front());
  Instruction *Ret = F->getEntryBlock().getTerminator();

  EXPECT_EQ(getCachedJavaType(Old, nullptr, nullptr, nullptr, Cache).Klass,
            22U);
  JavaTypeCacheInvalidationInfo Invalidated = Cache.invalidate({Old});
  EXPECT_EQ(Invalidated.BaseRemoved, 1U);
  EXPECT_EQ(Cache.baseSize(), 1U);

  Old->eraseFromParent();
  auto *Replacement = SelectInst::Create(F->getArg(2), F->getArg(1),
                                         F->getArg(1), "old",
                                         Ret->getIterator());
  DominatorTree DT(*F);
  EXPECT_EQ(
      getCachedJavaType(Replacement, nullptr, nullptr, nullptr, Cache).Klass,
      33U);
  EXPECT_EQ(getCachedJavaType(Replacement, nullptr, nullptr, nullptr, Cache),
            jeandle::getJavaType(Replacement, &DT, nullptr, nullptr));
}

TEST_F(JavaTypeQueryTest, CFGInvalidationRecomputesPhiAndRetainsLeafTypes) {
  Function *F = parse(R"(
    define void @test(ptr "java-klass"="22" %a,
                      ptr "java-klass"="33" %b, i1 %c) {
    entry:
      br i1 %c, label %left, label %right
    left:
      br label %merge
    right:
      br label %merge
    merge:
      %p = phi ptr [ %a, %left ], [ %b, %right ]
      ret void
    }
  )");
  ASSERT_NE(F, nullptr);
  DominatorTree DT(*F);
  JavaTypeCache Cache(F, JavaTypeCache::Mode::StableOracleEpoch);
  Cache.setStatsEnabled(true);
  auto *PN = cast<PHINode>(&block(*F, "merge")->front());
  EXPECT_EQ(getCachedJavaType(PN, &DT, nullptr, nullptr, Cache).Klass, 1U);
  BasicBlock *Right = block(*F, "right");
  Instruction *OldBranch = F->getEntryBlock().getTerminator();
  Cache.invalidate({OldBranch, Right->getTerminator()}, true);
  BranchInst::Create(block(*F, "left"), OldBranch->getIterator());
  OldBranch->eraseFromParent();
  PN->removeIncomingValue(Right, false);
  Right->eraseFromParent();
  DT.recalculate(*F);
  EXPECT_FALSE(verifyFunction(*F, &errs()));
  EXPECT_EQ(getCachedJavaType(F->getArg(1), &DT, nullptr, nullptr, Cache).Klass,
            33U);
  EXPECT_GT(Cache.Base.getStats().Hits, 0U);
  EXPECT_EQ(getCachedJavaType(PN, &DT, nullptr, nullptr, Cache).Klass, 22U);
  EXPECT_EQ(getCachedJavaType(PN, &DT, nullptr, nullptr, Cache),
            jeandle::getJavaType(PN, &DT, nullptr, nullptr));
}

TEST_F(JavaTypeQueryTest, GuardOperandChangeInvalidatesNonKeyDependencies) {
  Function *F = parse(IR);
  ASSERT_NE(F, nullptr);
  FunctionAnalysisManager FAM;
  PassBuilder PB;
  PB.registerFunctionAnalyses(FAM);
  auto &Result = FAM.getResult<JavaTypeAnalysis>(*F);
  Value *V = F->getArg(0);
  Instruction *Context = block(*F, "tail")->getTerminator();
  EXPECT_EQ(Result.getJavaType(V, Context).Klass, 22U);
  auto *Check = cast<CallInst>(&block(*F, "guard")->front());
  Result.invalidate(*Check);
  Check->setArgOperand(0, ConstantExpr::getIntToPtr(
                             ConstantInt::get(Type::getInt64Ty(C), 33),
                             PointerType::get(C, 0)));
  FAM.getResult<LazyValueAnalysis>(*F).clear();
  JavaType Cached = Result.getJavaType(V, Context);
  EXPECT_EQ(Cached.Klass, 33U);
  FunctionAnalysisManager ReferenceFAM;
  PassBuilder ReferencePB;
  ReferencePB.registerFunctionAnalyses(ReferenceFAM);
  auto &Reference = ReferenceFAM.getResult<JavaTypeAnalysis>(*F);
  EXPECT_EQ(Cached, Reference.getJavaType(V, Context));
  EXPECT_NE(statistics(FAM, F).find("base entries retained: 1"),
            std::string::npos);
}

TEST_F(JavaTypeQueryTest, FullInvalidationSwitchDropsAllEntries) {
  ScopedQueryOption<bool> Full("jeandle-java-type-force-full-invalidation", true);
  Function *F = parse(IR);
  ASSERT_NE(F, nullptr);
  FunctionAnalysisManager FAM;
  PassBuilder PB;
  PB.registerFunctionAnalyses(FAM);
  auto &Result = FAM.getResult<JavaTypeAnalysis>(*F);
  EXPECT_EQ(Result.getJavaType(F->getArg(0),
                              block(*F, "tail")->getTerminator()).Klass, 22U);
  Result.invalidate(*block(*F, "guard")->getTerminator());
  EXPECT_NE(statistics(FAM, F).find("current base entries: 0"), std::string::npos);
  EXPECT_NE(statistics(FAM, F).find("current edge facts entries: 0"),
            std::string::npos);
  EXPECT_NE(statistics(FAM, F).find("current final type entries: 0"),
            std::string::npos);
  EXPECT_NE(statistics(FAM, F).find("clears: 1"), std::string::npos);
}

TEST_F(JavaTypeQueryTest, UnsupportedInvalidationFallsBackToClear) {
  Function *F = parse(IR);
  ASSERT_NE(F, nullptr);
  DominatorTree DT(*F);
  JavaTypeCache Cache(F, JavaTypeCache::Mode::StableOracleEpoch);
  Cache.setStatsEnabled(true);
  EXPECT_EQ(getCachedJavaType(F->getArg(0), &DT,
                             block(*F, "tail")->getTerminator(), nullptr,
                             Cache).Klass, 22U);
  auto Removed = Cache.invalidate({F});
  EXPECT_TRUE(Removed.FullClear);
  EXPECT_EQ(Cache.baseSize(), 0U);
  EXPECT_EQ(Cache.pathFactsSize(), 0U);
  EXPECT_EQ(Cache.finalTypesSize(), 0U);
}

TEST_F(JavaTypeQueryTest, SelectiveResultStillDependsOnLVIInvalidation) {
  Function *F = parse(IR);
  ASSERT_NE(F, nullptr);
  FunctionAnalysisManager FAM;
  PassBuilder PB;
  PB.registerFunctionAnalyses(FAM);
  auto &Result = FAM.getResult<JavaTypeAnalysis>(*F);
  EXPECT_EQ(Result.getJavaType(F->getArg(0),
                              block(*F, "tail")->getTerminator()).Klass, 22U);
  PreservedAnalyses PA;
  PA.preserve<JavaTypeAnalysis>();
  PA.preserve<DominatorTreeAnalysis>();
  FAM.invalidate(*F, PA);
  EXPECT_EQ(FAM.getCachedResult<JavaTypeAnalysis>(*F), nullptr);
}

TEST_F(JavaTypeQueryTest, JavaTypeResultPreserveAndReuseBoundary) {
  Function *F = parse(IR);
  ASSERT_NE(F, nullptr);
  FunctionAnalysisManager FAM;
  PassBuilder PB;
  PB.registerFunctionAnalyses(FAM);
  auto *First = &FAM.getResult<JavaTypeAnalysis>(*F);
  Instruction *Context = block(*F, "tail")->getTerminator();
  EXPECT_EQ(First->getJavaType(F->getArg(0), Context).Klass, 22U);

  PreservedAnalyses FullyPreserved;
  FullyPreserved.preserve<JavaTypeAnalysis>();
  FullyPreserved.preserve<DominatorTreeAnalysis>();
  FullyPreserved.preserve<LazyValueAnalysis>();
  FAM.invalidate(*F, FullyPreserved);
  EXPECT_EQ(FAM.getCachedResult<JavaTypeAnalysis>(*F), First);
  EXPECT_EQ(FAM.getResult<JavaTypeAnalysis>(*F)
                .getJavaType(F->getArg(0), Context)
                .Klass,
            22U);

  PreservedAnalyses MissingDependency;
  MissingDependency.preserve<JavaTypeAnalysis>();
  MissingDependency.preserve<LazyValueAnalysis>();
  FAM.invalidate(*F, MissingDependency);
  EXPECT_EQ(FAM.getCachedResult<JavaTypeAnalysis>(*F), nullptr);
  // The allocator may reuse First's address for the fresh result. Lifetime is
  // established by the null cached-result check above, not pointer identity.
  auto &Fresh = FAM.getResult<JavaTypeAnalysis>(*F);
  EXPECT_EQ(Fresh.getJavaType(F->getArg(0), Context).Klass, 22U);
}

TEST_F(JavaTypeQueryTest, InvalidationWorkLimitFallsBackToClear) {
  Function *F = parse(R"(
    define void @test(ptr "java-klass"="22" %obj, i1 %c) {
      ret void
    }
  )");
  ASSERT_NE(F, nullptr);
  Instruction *Ret = F->getEntryBlock().getTerminator();
  Value *Previous = F->getArg(0);
  for (unsigned I = 0; I != 4100; ++I)
    Previous = SelectInst::Create(F->getArg(1), Previous, F->getArg(0),
                                  "derived", Ret->getIterator());
  JavaTypeCache Cache(F, JavaTypeCache::Mode::StableOracleEpoch);
  Cache.setStatsEnabled(true);
  EXPECT_EQ(getCachedJavaType(F->getArg(0), nullptr, nullptr, nullptr, Cache)
                .Klass,
            22U);
  auto Invalidated = Cache.invalidate({F->getArg(1)});
  EXPECT_TRUE(Invalidated.FullClear);
  EXPECT_EQ(Invalidated.ValuesVisited, 4097U);
  EXPECT_EQ(Cache.baseSize(), 0U);
}

TEST_F(JavaTypeQueryTest, DereferenceChangeDropsContextualResults) {
  Function *F = parse(R"(
    declare i1 @jeandle.check_instanceof(ptr, ptr nonnull)
    define void @test(ptr %obj, ptr %address) {
    entry:
      store i8 0, ptr %address
      %check = call i1 @jeandle.check_instanceof(ptr inttoptr (i64 22 to ptr), ptr %obj)
      br i1 %check, label %hit, label %miss
    hit:
      ret void
    miss:
      ret void
    }
  )");
  ASSERT_NE(F, nullptr);
  DominatorTree DT(*F);
  JavaTypeCache Cache(F, JavaTypeCache::Mode::StableOracleEpoch);
  Cache.setStatsEnabled(true);
  Instruction *Context = block(*F, "hit")->getTerminator();
  EXPECT_EQ(getCachedJavaType(F->getArg(0), &DT, Context, nullptr, Cache)
                .Klass,
            22U);
  // A store has no SSA users, but its dereference can affect LVI's null-edge
  // answers. Contextual entries must be discarded even for another key.
  Instruction *Store = &F->getEntryBlock().front();
  auto Invalidated = Cache.invalidate({Store});
  EXPECT_FALSE(Invalidated.FullClear);
  EXPECT_GT(Invalidated.FactsRemoved, 0U);
  EXPECT_EQ(Invalidated.FinalRemoved, 1U);
  EXPECT_EQ(Cache.baseSize(), 1U);
  Store->eraseFromParent();
  EXPECT_EQ(getCachedJavaType(F->getArg(0), &DT, Context, nullptr, Cache)
                .Klass,
            22U);
  EXPECT_EQ(Cache.Final.getStats().Hits, 0U);
}

TEST_F(JavaTypeQueryTest, StatisticsAreOptIn) {
  // With the switch off the analysis creates no observer: neither queries nor
  // invalidations are counted, and no clock is read.
  ScopedQueryOption<bool> Off("jeandle-java-type-stats", false);
  Function *F = parse(IR);
  ASSERT_NE(F, nullptr);
  FunctionAnalysisManager FAM;
  PassBuilder PB;
  PB.registerFunctionAnalyses(FAM);
  auto &Result = FAM.getResult<JavaTypeAnalysis>(*F);
  Instruction *Context = block(*F, "tail")->getTerminator();
  EXPECT_EQ(Result.getJavaType(F->getArg(0), Context).Klass, 22U);
  Result.invalidate(*block(*F, "guard")->getTerminator());
  std::string Text = statistics(FAM, F);
  for (StringRef Zero : {"queries: 0", "current base entries: 0",
                         "invalidation requests: 0", "clears: 0",
                         "total query time (ns): 0"})
    EXPECT_NE(Text.find(Zero.str()), std::string::npos) << Text;
}

TEST_F(JavaTypeQueryTest, NullPrefilterSkipsLVIForArgumentsAndEntrySelects) {
  std::string IR = "declare void @consume(ptr)\ndefine ptr @test(ptr %a, ptr "
                   "%b, i1 %pick) {\nentry:\n";
  std::string Previous = "%a";
  for (unsigned I = 0; I < 64; ++I) {
    std::string Name = "%s" + std::to_string(I);
    IR += Name + " = select i1 %pick, ptr " + Previous + ", ptr %b\n";
    Previous = Name;
  }
  IR += "call void @consume(ptr " + Previous +
        ")\nbr label %next\nnext:\nbr label %exit\nexit:\nret ptr " + Previous +
        "\n}\n";
  Function *F = parse(IR);
  ASSERT_NE(F, nullptr);
  FunctionAnalysisManager FAM;
  PassBuilder PB;
  PB.registerFunctionAnalyses(FAM);
  auto &LVI = FAM.getResult<LazyValueAnalysis>(*F);
  LVINullEdgeQuery Query(true);
  LVINullEdgeOracle Filtered{LVI, &Query}, Reference{LVI};
  Value *Root =
      cast<ReturnInst>(block(*F, "exit")->getTerminator())->getReturnValue();
  for (Value *V : SmallVector<Value *, 2>{F->getArg(0), Root})
    for (BasicBlock *From : {&F->getEntryBlock(), block(*F, "next")}) {
      BasicBlock *To =
          From == &F->getEntryBlock() ? block(*F, "next") : block(*F, "exit");
      EXPECT_EQ(Filtered(V, From, To), Reference(V, From, To));
    }
  EXPECT_EQ(Query.getStats().Filtered, 4U);
  EXPECT_EQ(Query.getStats().LVICalls, 0U);
}

TEST_F(JavaTypeQueryTest, NullPrefilterKeepsSelectAndPhiFallbacks) {
  Function *F = parse(R"(
    define ptr @test(ptr %obj) {
    entry:
      %check = icmp eq ptr %obj, null
      br i1 %check, label %nullarm, label %other
    nullarm:
      br label %join
    other:
      %selected = select i1 true, ptr null, ptr %obj
      br label %join
    join:
      %merged = phi ptr [ %obj, %nullarm ], [ %selected, %other ]
      br label %exit
    exit:
      ret ptr %merged
    }
  )");
  ASSERT_NE(F, nullptr);
  FunctionAnalysisManager FAM;
  PassBuilder PB;
  PB.registerFunctionAnalyses(FAM);
  auto &LVI = FAM.getResult<LazyValueAnalysis>(*F);
  LVINullEdgeQuery Query(true);
  LVINullEdgeOracle Filtered{LVI, &Query}, Reference{LVI};
  EXPECT_TRUE(
      Filtered(F->getArg(0), &F->getEntryBlock(), block(*F, "nullarm")));
  EXPECT_FALSE(Filtered(F->getArg(0), &F->getEntryBlock(), block(*F, "other")));
  for (StringRef Name : {"other", "join"}) {
    BasicBlock *From = block(*F, Name);
    Value *V = &From->front();
    BasicBlock *To = Name == "other" ? block(*F, "join") : block(*F, "exit");
    bool Expected = Reference(V, From, To);
    EXPECT_EQ(Filtered(V, From, To), Expected);
  }
  EXPECT_TRUE(Reference(F->getArg(0), block(*F, "nullarm"), block(*F, "join")));
  EXPECT_TRUE(Filtered(F->getArg(0), block(*F, "nullarm"), block(*F, "join")));
  EXPECT_EQ(Query.getStats().Structural, 2U);
  EXPECT_EQ(Query.getStats().LVICalls, 3U);
  EXPECT_EQ(Query.getStats().Filtered, 0U);
}

TEST_F(JavaTypeQueryTest, NullPrefilterKeepsReturnedAliasesAndIntegerTests) {
  Function *F = parse(R"(
    declare ptr @identity(ptr returned)
    define ptr @test(ptr %obj) {
    entry:
      %alias = call ptr @identity(ptr %obj)
      %bits = ptrtoint ptr %alias to i64
      %check = icmp eq i64 %bits, 0
      br i1 %check, label %next, label %other
    next:
      br label %exit
    exit:
      ret ptr %alias
    other:
      ret ptr %obj
    }
  )");
  ASSERT_NE(F, nullptr);
  FunctionAnalysisManager FAM;
  PassBuilder PB;
  PB.registerFunctionAnalyses(FAM);
  auto &LVI = FAM.getResult<LazyValueAnalysis>(*F);
  LVINullEdgeQuery Query(true);
  LVINullEdgeOracle Filtered{LVI, &Query}, Reference{LVI};
  auto *From = block(*F, "next");
  auto *To = block(*F, "exit");
  for (Value *V :
       SmallVector<Value *, 2>{F->getArg(0), &F->getEntryBlock().front()})
    EXPECT_EQ(Filtered(V, From, To), Reference(V, From, To));
  EXPECT_EQ(Query.getStats().Filtered, 0U);
  EXPECT_EQ(Query.getStats().LVICalls, 2U);
}

TEST_F(JavaTypeQueryTest, NullPrefilterDoesNotStripUnprovenFreeze) {
  Function *F = parse(R"(
    define ptr @test() {
    entry:
      %frozen = freeze ptr poison
      br label %next
    next:
      ret ptr %frozen
    }
  )");
  ASSERT_NE(F, nullptr);
  FunctionAnalysisManager FAM;
  PassBuilder PB;
  PB.registerFunctionAnalyses(FAM);
  auto &LVI = FAM.getResult<LazyValueAnalysis>(*F);
  LVINullEdgeQuery Query(true);
  LVINullEdgeOracle Filtered{LVI, &Query}, Reference{LVI};
  auto *V = &F->getEntryBlock().front();
  EXPECT_EQ(Filtered(V, &F->getEntryBlock(), block(*F, "next")),
            Reference(V, &F->getEntryBlock(), block(*F, "next")));
  EXPECT_EQ(Query.getStats().Filtered, 0U);
  EXPECT_EQ(Query.getStats().LVICalls, 1U);
}

TEST_F(JavaTypeQueryTest, NullPrefilterWorkLimitFallsBackToLVI) {
  std::string IR =
      "declare void @consume(ptr)\ndefine ptr @test(ptr %obj) {\nentry:\n";
  for (unsigned I = 0; I < 300; ++I)
    IR += "call void @consume(ptr %obj)\n";
  IR += "br label %next\nnext:\nret ptr %obj\n}\n";
  Function *F = parse(IR);
  ASSERT_NE(F, nullptr);
  FunctionAnalysisManager FAM;
  PassBuilder PB;
  PB.registerFunctionAnalyses(FAM);
  auto &LVI = FAM.getResult<LazyValueAnalysis>(*F);
  LVINullEdgeQuery Query(true);
  LVINullEdgeOracle Filtered{LVI, &Query}, Reference{LVI};
  EXPECT_EQ(Filtered(F->getArg(0), &F->getEntryBlock(), block(*F, "next")),
            Reference(F->getArg(0), &F->getEntryBlock(), block(*F, "next")));
  EXPECT_EQ(Query.getStats().Filtered, 0U);
  EXPECT_EQ(Query.getStats().LVICalls, 1U);
  EXPECT_EQ(Query.getStats().FilterFallbacks, 1U);
}

TEST_F(JavaTypeQueryTest, NullPrefilterNewQueryRefreshesAfterIRMaintenance) {
  Function *F = parse(R"(
    define ptr @test(ptr %obj) {
    entry:
      br label %next
    next:
      br label %exit
    exit:
      ret ptr %obj
    other:
      ret ptr null
    }
  )");
  ASSERT_NE(F, nullptr);
  FunctionAnalysisManager FAM;
  PassBuilder PB;
  PB.registerFunctionAnalyses(FAM);
  auto &LVI = FAM.getResult<LazyValueAnalysis>(*F);
  LVINullEdgeQuery BeforeQuery(true);
  LVINullEdgeOracle Before{LVI, &BeforeQuery};
  EXPECT_FALSE(Before(F->getArg(0), block(*F, "next"), block(*F, "exit")));
  EXPECT_EQ(BeforeQuery.getStats().Filtered, 1U);
  Instruction *Old = F->getEntryBlock().getTerminator();
  auto *Test = new ICmpInst(
      Old->getIterator(), ICmpInst::ICMP_EQ, F->getArg(0),
      ConstantPointerNull::get(cast<PointerType>(F->getArg(0)->getType())));
  BranchInst::Create(block(*F, "next"), block(*F, "other"), Test,
                     Old->getIterator());
  Old->eraseFromParent();
  LVI.clear();
  LVINullEdgeQuery AfterQuery(true);
  LVINullEdgeOracle After{LVI, &AfterQuery}, Reference{LVI};
  bool Expected = Reference(F->getArg(0), block(*F, "next"), block(*F, "exit"));
  EXPECT_TRUE(Expected);
  EXPECT_EQ(After(F->getArg(0), block(*F, "next"), block(*F, "exit")),
            Expected);
  EXPECT_EQ(AfterQuery.getStats().Filtered, 0U);
  EXPECT_EQ(AfterQuery.getStats().LVICalls, 1U);
}

TEST_F(JavaTypeQueryTest, NullPrefilterDepthLimitFallsBackToLVI) {
  std::string IR = "define ptr @test(ptr %a, ptr %b, i1 %pick) {\nentry:\n";
  std::string Previous = "%a";
  for (unsigned I = 0; I < 80; ++I) {
    std::string Name = "%s" + std::to_string(I);
    IR += Name + " = select i1 %pick, ptr " + Previous + ", ptr %b\n";
    Previous = Name;
  }
  IR += "br label %next\nnext:\nret ptr " + Previous + "\n}\n";
  Function *F = parse(IR);
  ASSERT_NE(F, nullptr);
  FunctionAnalysisManager FAM;
  PassBuilder PB;
  PB.registerFunctionAnalyses(FAM);
  auto &LVI = FAM.getResult<LazyValueAnalysis>(*F);
  Value *V =
      cast<ReturnInst>(block(*F, "next")->getTerminator())->getReturnValue();
  LVINullEdgeQuery Query(true);
  LVINullEdgeOracle Filtered{LVI, &Query}, Reference{LVI};
  EXPECT_EQ(Filtered(V, &F->getEntryBlock(), block(*F, "next")),
            Reference(V, &F->getEntryBlock(), block(*F, "next")));
  EXPECT_EQ(Query.getStats().Filtered, 0U);
  EXPECT_EQ(Query.getStats().LVICalls, 1U);
  EXPECT_EQ(Query.getStats().FilterFallbacks, 1U);
}

} // namespace
