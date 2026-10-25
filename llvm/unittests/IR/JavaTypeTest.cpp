//===- JavaTypeTest.cpp - Java base type queries
//---------------------------===//
//
// Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM
// Exceptions. See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#include "llvm/IR/Jeandle/JavaType.h"
#include "llvm/Analysis/AssumptionCache.h"
#include "llvm/Analysis/LazyValueInfo.h"
#include "llvm/Analysis/TargetTransformInfo.h"
#include "llvm/AsmParser/Parser.h"
#include "llvm/IR/Dominators.h"
#include "llvm/IR/GlobalAlias.h"
#include "llvm/IR/IRBuilder.h"
#include "llvm/IR/Jeandle/VMCallback.h"
#include "llvm/IR/Module.h"
#include "llvm/IR/PassInstrumentation.h"
#include "llvm/IR/PassManager.h"
#include "llvm/IR/Verifier.h"
#include "llvm/Support/SourceMgr.h"
#include "llvm/Transforms/Jeandle/TypeCheckElimination.h"
#include "gtest/gtest.h"

using namespace llvm;
using namespace llvm::jeandle;

namespace {

class JavaBaseTypeTest : public testing::Test {
protected:
  LLVMContext Context;
  Module M{"java-type-test", Context};
  IRBuilder<> B{Context};
  VMCallbacks Saved{};
  bool HadCallbacks = false;
  Function *F = nullptr;
  BasicBlock *Entry = nullptr;
  BasicBlock *Loop = nullptr;
  static inline unsigned CommonSuperQueries = 0;
  static inline unsigned InterfaceQueries = 0;
  static inline unsigned SubtypeQueries = 0;

  void SetUp() override {
    CommonSuperQueries = 0;
    InterfaceQueries = 0;
    if (const VMCallbacks *CB = getVMCallbacks()) {
      Saved = *CB;
      HadCallbacks = true;
    }
    VMCallbacks CB{};
    CB.IsInterface = [](uintptr_t) { return false; };
    CB.IsUnverifiedInterface = [](uintptr_t) { return false; };
    CB.IsEffectivelyFinal = [](uintptr_t) { return false; };
    CB.GetSecondarySupers = [](uintptr_t) {
      ++InterfaceQueries;
      return std::vector<uintptr_t>{};
    };
    CB.IsSubtype = [](uintptr_t A, uintptr_t B) { return A == B || B == 5; };
    CB.GetCommonSuperKlass = [](uintptr_t A, uintptr_t B) {
      ++CommonSuperQueries;
      return A == B ? A : uintptr_t(5);
    };
    registerVMCallbacks(CB);
    auto *Ptr = PointerType::get(Context, 1);
    F = Function::Create(
        FunctionType::get(Ptr, {Ptr, Ptr, B.getInt1Ty(), Ptr}, false),
        GlobalValue::ExternalLinkage, "test", M);
    Entry = BasicBlock::Create(Context, "entry", F);
    Loop = BasicBlock::Create(Context, "loop", F);
    B.SetInsertPoint(Entry);
    B.CreateBr(Loop);
    B.SetInsertPoint(Loop);
  }

  // Registering a zeroed table would leave an empty-but-registered callback
  // state behind when no callbacks existed before the test; restore only
  // what was actually there.
  void TearDown() override {
    if (HadCallbacks)
      registerVMCallbacks(Saved);
  }

  Argument *seed(unsigned Index, unsigned Klass, bool Exact = false) {
    F->addParamAttr(
        Index, Attribute::get(Context, "java-klass", std::to_string(Klass)));
    if (Exact)
      F->addParamAttr(Index, Attribute::get(Context, "java-klass-exact"));
    return F->getArg(Index);
  }

  JavaType query(Value *V) { return getJavaType(V, nullptr, nullptr, nullptr); }

  JavaType queryAt(Value *V, Instruction *At, DominatorTree &DT) {
    return getJavaType(
        V, &DT, At, [](Value *, BasicBlock *, BasicBlock *) { return false; });
  }

  Value *typedSelectChain(unsigned Depth) {
    Value *V = seed(0, 9, true);
    Value *Other = seed(1, 22, true);
    for (unsigned I = 0; I != Depth; ++I)
      V = B.CreateSelect(F->getArg(2), V, Other);
    return V;
  }

  void checkPattern(StringRef Body, uintptr_t BaseKlass, bool BaseExact,
                    uintptr_t ContextKlass, bool ContextExact) {
    SCOPED_TRACE(Body.str());
    std::string IR = R"IR(
      declare i1 @jeandle.check_instanceof(ptr, ptr addrspace(1) nonnull)
      declare ptr addrspace(1) @identity(ptr addrspace(1) returned)
      declare ptr addrspace(1) @nonnull_identity(ptr addrspace(1) returned nonnull)
      define ptr addrspace(1) @pattern(
        ptr addrspace(1) noundef "java-klass"="9" "java-klass-exact" %a,
        ptr addrspace(1) noundef "java-klass"="9" "java-klass-exact" %b,
        ptr addrspace(1) "java-klass"="9" "java-klass-exact" %maybe,
        ptr addrspace(1) %unknown, ptr %slot,
        i1 noundef %pick, i1 %maybecond, i32 noundef %x, i32 noundef %y) {
    )IR";
    IR += Body.str();
    IR += R"IR(
      }
      !0 = !{}
      !1 = !{i64 9}
    )IR";
    SMDiagnostic Error;
    auto Parsed = parseAssemblyString(IR, Error, Context);
    ASSERT_NE(Parsed, nullptr) << Error.getMessage().str();
    ASSERT_FALSE(verifyModule(*Parsed, &errs()));
    auto *Pattern = Parsed->getFunction("pattern");
    auto *Return = cast<ReturnInst>(Pattern->back().getTerminator());
    Value *V = Return->getReturnValue();
    EXPECT_EQ(query(V), JavaType(BaseKlass, BaseExact));
    DominatorTree DT(*Pattern);
    EXPECT_EQ(queryAt(V, Return, DT), JavaType(ContextKlass, ContextExact));
  }

  void checkPattern(StringRef Body, uintptr_t Klass, bool Exact = true) {
    checkPattern(Body, Klass, Exact, Klass, Exact);
  }

  void checkGuardedIncomingReuse(bool UnknownFirst) {
    constexpr unsigned Depth = 2048;
    constexpr unsigned Arms = 64;
    Value *Known = seed(0, 9);
    Value *Shared = F->getArg(3);
    if (UnknownFirst) {
      for (unsigned I = 0; I != Depth; ++I)
        Shared = B.CreateSelect(F->getArg(2), Shared, Known);
    } else {
      Shared = typedSelectChain(Depth);
    }
    Value *Other = UnknownFirst ? Known : F->getArg(3);
    auto *Fallback = BasicBlock::Create(Context, "fallback", F);
    auto *Merge = BasicBlock::Create(Context, "merge", F);
    auto *Root = PHINode::Create(F->getReturnType(), Arms, "root", Merge);
    auto *Dispatch = B.CreateSwitch(
        B.CreatePtrToInt(F->getArg(1), B.getInt64Ty()), Fallback, Arms);
    auto *RawPtr = PointerType::get(Context, 0);
    FunctionCallee Check = M.getOrInsertFunction(
        "jeandle.check_instanceof", B.getInt1Ty(), RawPtr, F->getReturnType());
    auto *Klass = ConstantExpr::getIntToPtr(B.getInt64(9), RawPtr);
    for (unsigned I = 0; I != Arms; ++I) {
      auto *Guard = BasicBlock::Create(Context, "guard", F);
      auto *Accepted = BasicBlock::Create(Context, "accepted", F);
      Dispatch->addCase(B.getInt64(I), Guard);
      B.SetInsertPoint(Guard);
      auto *Incoming = B.CreateSelect(F->getArg(2), Shared, Other);
      auto *Condition = B.CreateCall(Check, {Klass, Incoming});
      B.CreateCondBr(Condition, Accepted, Fallback);
      B.SetInsertPoint(Accepted);
      B.CreateBr(Merge);
      Root->addIncoming(Incoming, Accepted);
    }
    B.SetInsertPoint(Fallback);
    B.CreateRet(
        ConstantPointerNull::get(cast<PointerType>(F->getReturnType())));
    B.SetInsertPoint(Merge);
    auto *Return = B.CreateRet(Root);
    ASSERT_FALSE(verifyFunction(*F));
    DominatorTree DT(*F);
    JavaType T = queryAt(Root, Return, DT);
    EXPECT_EQ(T.Klass, 9U);
    EXPECT_FALSE(T.Exact);
    if (!UnknownFirst) {
      // The typed chain must be expanded once and then served from the
      // query's completion cache; without reuse every arm re-walked all
      // Depth levels. The unknown variant cannot be bounded this way: its
      // absorbing unknown arm fires no CommonSuperKlass callback at all.
      EXPECT_LE(CommonSuperQueries, Depth + 4 * Arms);
    }
  }

  // The fixture's default class lattice: 9 and 22 are unrelated subclasses
  // of 5 and both implement interface 7.
  void registerCommonInterfaceCallbacks() {
    VMCallbacks CB = *getVMCallbacks();
    CB.IsInterface = [](uintptr_t K) { return K == 7; };
    CB.GetSecondarySupers = [](uintptr_t K) {
      return (K == 9 || K == 22) ? std::vector<uintptr_t>{7}
                                 : std::vector<uintptr_t>{};
    };
    registerVMCallbacks(CB);
  }
};

TEST_F(JavaBaseTypeTest, SharedDagAboveSelfCycle) {
  auto *P = B.CreatePHI(F->getReturnType(), 2);
  P->addIncoming(seed(0, 9, true), Entry);
  P->addIncoming(P, Loop);
  BasicBlock *Previous = Loop;
  // Each merge has two CFG edges carrying the same value. The old recursion
  // walked both paths again because the bottom self-cycle disabled caching.
  for (unsigned I = 0; I != 40; ++I) {
    auto *Next = BasicBlock::Create(Context, "merge", F);
    B.SetInsertPoint(Previous);
    B.CreateCondBr(F->getArg(2), Next, Next);
    B.SetInsertPoint(Next);
    auto *Merge = B.CreatePHI(F->getReturnType(), 2);
    Merge->addIncoming(P, Previous);
    Merge->addIncoming(P, Previous);
    P = Merge;
    Previous = Next;
  }
  B.CreateBr(Loop);
  // Close the seed PHI using the real back-edge predecessor.
  cast<PHINode>(&Loop->front())->setIncomingBlock(1, Previous);
  JavaType T = query(P);
  EXPECT_EQ(T.Klass, 9U);
  EXPECT_TRUE(T.Exact);
}

TEST_F(JavaBaseTypeTest, MutualCycleJoinsAllSeeds) {
  auto *A = B.CreatePHI(F->getReturnType(), 2);
  auto *C = B.CreatePHI(F->getReturnType(), 2);
  A->addIncoming(seed(0, 9, true), Entry);
  A->addIncoming(C, Loop);
  C->addIncoming(seed(1, 22, true), Entry);
  C->addIncoming(A, Loop);
  EXPECT_EQ(query(A).Klass, 5U);
  EXPECT_EQ(query(C).Klass, 5U);
  EXPECT_FALSE(query(A).Exact);
}

TEST_F(JavaBaseTypeTest, UnknownArmMustNotBeDropped) {
  auto *P = B.CreatePHI(F->getReturnType(), 3);
  P->addIncoming(seed(0, 9, true), Entry);
  P->addIncoming(P, Loop);
  P->addIncoming(F->getArg(1), Loop);
  EXPECT_TRUE(query(P).isUnknown());
  // A genuinely unknown arm absorbs the join. Literal null and poison arms
  // are different: under the non-null oop contract they are vacuous (the
  // value cannot be a non-null oop on those executions), so the typed arm
  // survives. Undef can materialize an arbitrary oop and stays absorbing.
  P->setIncomingValue(
      2, ConstantPointerNull::get(cast<PointerType>(F->getReturnType())));
  EXPECT_EQ(query(P), JavaType(9, true));
  P->setIncomingValue(2, PoisonValue::get(F->getReturnType()));
  EXPECT_EQ(query(P), JavaType(9, true));
  P->setIncomingValue(2, UndefValue::get(F->getReturnType()));
  EXPECT_TRUE(query(P).isUnknown());
}

TEST_F(JavaBaseTypeTest, UnknownSelectArmShortCircuits) {
  Value *Known = typedSelectChain(2048);
  auto *Root = B.CreateSelect(F->getArg(2), F->getArg(3), Known);
  B.CreateRet(Root);
  ASSERT_FALSE(verifyFunction(*F));
  EXPECT_TRUE(query(Root).isUnknown());
  EXPECT_EQ(CommonSuperQueries, 0U);
  EXPECT_EQ(InterfaceQueries, 0U);
}

TEST_F(JavaBaseTypeTest, NestedUnknownArmShortCircuits) {
  Value *Known = typedSelectChain(2048);
  auto *Unknown = B.CreateSelect(F->getArg(2), F->getArg(3), F->getArg(0));
  auto *Root = B.CreateSelect(F->getArg(2), Unknown, Known);
  B.CreateRet(Root);
  ASSERT_FALSE(verifyFunction(*F));
  EXPECT_TRUE(query(Root).isUnknown());
  EXPECT_EQ(CommonSuperQueries, 0U);
  EXPECT_EQ(InterfaceQueries, 0U);
}

TEST_F(JavaBaseTypeTest, UnknownPhiArmShortCircuits) {
  auto *Root = B.CreatePHI(F->getReturnType(), 2);
  Root->addIncoming(F->getArg(3), Entry);
  Root->addIncoming(typedSelectChain(2048), Loop);
  auto *Exit = BasicBlock::Create(Context, "exit", F);
  B.CreateCondBr(F->getArg(2), Loop, Exit);
  B.SetInsertPoint(Exit);
  B.CreateRet(Root);
  ASSERT_FALSE(verifyFunction(*F));
  EXPECT_TRUE(query(Root).isUnknown());
  EXPECT_EQ(CommonSuperQueries, 0U);
  EXPECT_EQ(InterfaceQueries, 0U);
}

TEST_F(JavaBaseTypeTest, ContextQueryReusesCompletedCycle) {
  auto *A = B.CreatePHI(F->getReturnType(), 2);
  auto *C = B.CreatePHI(F->getReturnType(), 2);
  A->addIncoming(seed(0, 9, true), Entry);
  A->addIncoming(C, Loop);
  C->addIncoming(seed(1, 22, true), Entry);
  C->addIncoming(A, Loop);
  auto *Fork = BasicBlock::Create(Context, "fork", F);
  auto *Left = BasicBlock::Create(Context, "left", F);
  auto *Right = BasicBlock::Create(Context, "right", F);
  auto *Merge = BasicBlock::Create(Context, "merge", F);
  B.CreateCondBr(F->getArg(2), Loop, Fork);
  B.SetInsertPoint(Fork);
  B.CreateCondBr(F->getArg(2), Left, Right);
  B.SetInsertPoint(Left);
  auto *LeftValue = B.CreateSelect(F->getArg(2), A, F->getArg(0));
  B.CreateBr(Merge);
  B.SetInsertPoint(Right);
  auto *RightValue = B.CreateSelect(F->getArg(2), C, F->getArg(1));
  B.CreateBr(Merge);
  B.SetInsertPoint(Merge);
  auto *Root = B.CreatePHI(F->getReturnType(), 2);
  Root->addIncoming(LeftValue, Left);
  Root->addIncoming(RightValue, Right);
  auto *Return = B.CreateRet(Root);
  ASSERT_FALSE(verifyFunction(*F));
  DominatorTree DT(*F);
  JavaType T = queryAt(Root, Return, DT);
  EXPECT_EQ(T.Klass, 5U);
  EXPECT_FALSE(T.Exact);
}

TEST_F(JavaBaseTypeTest, ContextGuardDoesNotPolluteBaseCache) {
  auto *A = B.CreatePHI(F->getReturnType(), 2);
  auto *C = B.CreatePHI(F->getReturnType(), 2);
  A->addIncoming(seed(0, 9, true), Entry);
  A->addIncoming(C, Loop);
  C->addIncoming(seed(1, 22, true), Entry);
  C->addIncoming(A, Loop);
  auto *Fork = BasicBlock::Create(Context, "fork", F);
  auto *Left = BasicBlock::Create(Context, "left", F);
  auto *Right = BasicBlock::Create(Context, "right", F);
  auto *Merge = BasicBlock::Create(Context, "merge", F);
  B.CreateCondBr(F->getArg(2), Loop, Fork);
  B.SetInsertPoint(Fork);
  auto *Shared = B.CreateSelect(F->getArg(2), A, C);
  auto *RawPtr = PointerType::get(Context, 0);
  FunctionCallee Check = M.getOrInsertFunction(
      "jeandle.check_instanceof", B.getInt1Ty(), RawPtr, F->getReturnType());
  auto *Klass = ConstantExpr::getIntToPtr(B.getInt64(9), RawPtr);
  auto *Condition = B.CreateCall(Check, {Klass, Shared});
  B.CreateCondBr(Condition, Left, Right);
  B.SetInsertPoint(Left);
  auto *LeftEnd = B.CreateBr(Merge);
  B.SetInsertPoint(Right);
  B.CreateBr(Merge);
  B.SetInsertPoint(Merge);
  auto *Root = B.CreatePHI(F->getReturnType(), 2);
  Root->addIncoming(Shared, Left);
  Root->addIncoming(Shared, Right);
  auto *Return = B.CreateRet(Root);
  ASSERT_FALSE(verifyFunction(*F));
  DominatorTree DT(*F);
  EXPECT_EQ(queryAt(Shared, LeftEnd, DT).Klass, 9U);
  JavaType T = queryAt(Root, Return, DT);
  EXPECT_EQ(T.Klass, 5U);
  EXPECT_FALSE(T.Exact);
}

TEST_F(JavaBaseTypeTest, GuardedIncomingValuesReuseSharedUnknownChain) {
  checkGuardedIncomingReuse(true);
}

TEST_F(JavaBaseTypeTest, GuardedIncomingValuesReuseSharedTypedChain) {
  checkGuardedIncomingReuse(false);
}

TEST_F(JavaBaseTypeTest, NestedPhisCompleteSharedInputsBeforeShortCircuit) {
  constexpr unsigned Depth = 2048;
  constexpr unsigned Arms = 64;
  Value *Shared = typedSelectChain(Depth);
  auto *Fallback = BasicBlock::Create(Context, "fallback", F);
  auto *Merge = BasicBlock::Create(Context, "merge", F);
  auto *Root = PHINode::Create(F->getReturnType(), Arms, "root", Merge);
  auto *Dispatch = B.CreateSwitch(
      B.CreatePtrToInt(F->getArg(1), B.getInt64Ty()), Fallback, Arms);
  auto *RawPtr = PointerType::get(Context, 0);
  FunctionCallee Check = M.getOrInsertFunction(
      "jeandle.check_instanceof", B.getInt1Ty(), RawPtr, F->getReturnType());
  auto *Klass = ConstantExpr::getIntToPtr(B.getInt64(9), RawPtr);
  for (unsigned I = 0; I != Arms; ++I) {
    auto *Fork = BasicBlock::Create(Context, "fork", F);
    auto *Typed = BasicBlock::Create(Context, "typed", F);
    auto *Unknown = BasicBlock::Create(Context, "unknown", F);
    auto *Other = BasicBlock::Create(Context, "other", F);
    auto *InnerMerge = BasicBlock::Create(Context, "inner_merge", F);
    auto *Accepted = BasicBlock::Create(Context, "accepted", F);
    Dispatch->addCase(B.getInt64(I), Fork);
    B.SetInsertPoint(Fork);
    auto *Choice = B.CreateSwitch(
        B.CreatePtrToInt(F->getArg(3), B.getInt64Ty()), Other, 2);
    Choice->addCase(B.getInt64(0), Typed);
    Choice->addCase(B.getInt64(1), Unknown);
    for (BasicBlock *BB : {Typed, Unknown, Other}) {
      B.SetInsertPoint(BB);
      B.CreateBr(InnerMerge);
    }
    B.SetInsertPoint(InnerMerge);
    auto *Inner = B.CreatePHI(F->getReturnType(), 3);
    Inner->addIncoming(Shared, Typed);
    Inner->addIncoming(F->getArg(3), Unknown);
    Inner->addIncoming(F->getArg(1), Other);
    auto *Incoming = B.CreateSelect(F->getArg(2), Inner, F->getArg(0));
    B.CreateCondBr(B.CreateCall(Check, {Klass, Incoming}), Accepted, Fallback);
    B.SetInsertPoint(Accepted);
    B.CreateBr(Merge);
    Root->addIncoming(Incoming, Accepted);
  }
  B.SetInsertPoint(Fallback);
  B.CreateRet(ConstantPointerNull::get(cast<PointerType>(F->getReturnType())));
  B.SetInsertPoint(Merge);
  auto *Return = B.CreateRet(Root);
  ASSERT_FALSE(verifyFunction(*F));
  DominatorTree DT(*F);
  JavaType T = queryAt(Root, Return, DT);
  EXPECT_EQ(T.Klass, 9U);
  EXPECT_FALSE(T.Exact);
  EXPECT_LE(CommonSuperQueries, Depth + 4 * Arms);
}

TEST_F(JavaBaseTypeTest, SelectCycleWithTypedSiblingJoinsSeeds) {
  B.SetInsertPoint(Entry->getTerminator());
  Value *Other = typedSelectChain(2048);
  B.SetInsertPoint(Loop);
  auto *P = B.CreatePHI(F->getReturnType(), 2);
  auto *Selected = B.CreateSelect(F->getArg(2), P, Other);
  P->addIncoming(F->getArg(0), Entry);
  P->addIncoming(Selected, Loop);
  auto *Exit = BasicBlock::Create(Context, "exit", F);
  B.CreateCondBr(F->getArg(2), Loop, Exit);
  B.SetInsertPoint(Exit);
  B.CreateRet(P);
  ASSERT_FALSE(verifyFunction(*F));
  JavaType T = query(P);
  EXPECT_EQ(T.Klass, 5U);
  EXPECT_FALSE(T.Exact);
  // The typed sibling chain is expanded once, not once per cycle entry.
  EXPECT_LE(CommonSuperQueries, 2048 + 4);
}

TEST_F(JavaBaseTypeTest, SelectCycleThroughPhiJoinsSeeds) {
  B.SetInsertPoint(Entry->getTerminator());
  Value *Other = typedSelectChain(2048);
  B.SetInsertPoint(Loop);
  auto *P = B.CreatePHI(F->getReturnType(), 2);
  auto *Q = B.CreatePHI(F->getReturnType(), 2);
  auto *Selected = B.CreateSelect(F->getArg(2), Q, Other);
  P->addIncoming(F->getArg(0), Entry);
  P->addIncoming(Selected, Loop);
  Q->addIncoming(F->getArg(0), Entry);
  Q->addIncoming(P, Loop);
  auto *Exit = BasicBlock::Create(Context, "exit", F);
  B.CreateCondBr(F->getArg(2), Loop, Exit);
  B.SetInsertPoint(Exit);
  B.CreateRet(P);
  ASSERT_FALSE(verifyFunction(*F));
  JavaType T = query(P);
  EXPECT_EQ(T.Klass, 5U);
  EXPECT_FALSE(T.Exact);
  EXPECT_LE(CommonSuperQueries, 2048 + 4);
}

TEST_F(JavaBaseTypeTest, NonPhiAncestorOutsideCyclePreservesType) {
  auto *A = B.CreatePHI(F->getReturnType(), 2);
  auto *C = B.CreatePHI(F->getReturnType(), 2);
  A->addIncoming(seed(0, 9, true), Entry);
  A->addIncoming(C, Loop);
  C->addIncoming(seed(1, 22, true), Entry);
  C->addIncoming(A, Loop);
  auto *Exit = BasicBlock::Create(Context, "exit", F);
  B.CreateCondBr(F->getArg(2), Loop, Exit);
  B.SetInsertPoint(Exit);
  auto *Root = B.CreateSelect(F->getArg(2), A, C);
  B.CreateRet(Root);
  ASSERT_FALSE(verifyFunction(*F));
  JavaType T = query(Root);
  EXPECT_EQ(T.Klass, 5U);
  EXPECT_FALSE(T.Exact);
}

TEST_F(JavaBaseTypeTest, CrossBranchSelectCycleJoinsSeeds) {
  B.SetInsertPoint(Entry->getTerminator());
  Value *Other = typedSelectChain(2048);
  B.SetInsertPoint(Loop);
  auto *A = B.CreatePHI(F->getReturnType(), 3);
  auto *C = B.CreatePHI(F->getReturnType(), 3);
  auto *Left = BasicBlock::Create(Context, "left", F);
  auto *Right = BasicBlock::Create(Context, "right", F);
  auto *Exit = BasicBlock::Create(Context, "exit", F);
  B.CreateCondBr(F->getArg(2), Left, Right);
  B.SetInsertPoint(Left);
  B.CreateBr(Loop);
  B.SetInsertPoint(Right);
  auto *Selected = B.CreateSelect(F->getArg(2), C, Other);
  B.CreateCondBr(F->getArg(2), Loop, Exit);
  A->addIncoming(F->getArg(0), Entry);
  A->addIncoming(C, Left);
  A->addIncoming(Selected, Right);
  C->addIncoming(F->getArg(0), Entry);
  C->addIncoming(A, Left);
  C->addIncoming(A, Right);
  B.SetInsertPoint(Exit);
  B.CreateRet(A);
  ASSERT_FALSE(verifyFunction(*F));
  JavaType T = query(A);
  EXPECT_EQ(T.Klass, 5U);
  EXPECT_FALSE(T.Exact);
  EXPECT_LE(CommonSuperQueries, 2048 + 4);
}

TEST_F(JavaBaseTypeTest, CrossBranchPurePhiCyclePreservesType) {
  auto *A = B.CreatePHI(F->getReturnType(), 3);
  auto *C = B.CreatePHI(F->getReturnType(), 3);
  auto *D = B.CreatePHI(F->getReturnType(), 3);
  auto *Left = BasicBlock::Create(Context, "left", F);
  auto *Right = BasicBlock::Create(Context, "right", F);
  auto *Exit = BasicBlock::Create(Context, "exit", F);
  B.CreateCondBr(F->getArg(2), Left, Right);
  B.SetInsertPoint(Left);
  B.CreateBr(Loop);
  B.SetInsertPoint(Right);
  B.CreateCondBr(F->getArg(2), Loop, Exit);
  A->addIncoming(seed(0, 9, true), Entry);
  A->addIncoming(C, Left);
  A->addIncoming(D, Right);
  C->addIncoming(seed(1, 22, true), Entry);
  C->addIncoming(A, Left);
  C->addIncoming(A, Right);
  D->addIncoming(F->getArg(0), Entry);
  D->addIncoming(C, Left);
  D->addIncoming(C, Right);
  B.SetInsertPoint(Exit);
  B.CreateRet(A);
  ASSERT_FALSE(verifyFunction(*F));
  JavaType T = query(A);
  EXPECT_EQ(T.Klass, 5U);
  EXPECT_FALSE(T.Exact);
}

TEST_F(JavaBaseTypeTest, CycleShortCircuitPreservesIndependentPhiCache) {
  auto *A = B.CreatePHI(F->getReturnType(), 2);
  auto *C = B.CreatePHI(F->getReturnType(), 2);
  auto *P = B.CreatePHI(F->getReturnType(), 2);
  A->addIncoming(seed(0, 9, true), Entry);
  A->addIncoming(C, Loop);
  C->addIncoming(seed(1, 22, true), Entry);
  C->addIncoming(A, Loop);
  P->addIncoming(F->getArg(0), Entry);
  auto *Selected = B.CreateSelect(F->getArg(2), P, F->getArg(0));
  P->addIncoming(Selected, Loop);
  auto *Fork = BasicBlock::Create(Context, "fork", F);
  auto *Guard = BasicBlock::Create(Context, "guard", F);
  auto *Accepted = BasicBlock::Create(Context, "accepted", F);
  auto *Right = BasicBlock::Create(Context, "right", F);
  auto *Fallback = BasicBlock::Create(Context, "fallback", F);
  auto *Merge = BasicBlock::Create(Context, "merge", F);
  B.CreateCondBr(F->getArg(2), Loop, Fork);
  B.SetInsertPoint(Fork);
  B.CreateCondBr(F->getArg(2), Guard, Right);
  B.SetInsertPoint(Guard);
  // Completed A/C types must survive the unsupported cycle in the other arm.
  auto *LeftValue = B.CreateSelect(F->getArg(2), A, P);
  auto *RawPtr = PointerType::get(Context, 0);
  FunctionCallee Check = M.getOrInsertFunction(
      "jeandle.check_instanceof", B.getInt1Ty(), RawPtr, F->getReturnType());
  auto *Klass = ConstantExpr::getIntToPtr(B.getInt64(9), RawPtr);
  B.CreateCondBr(B.CreateCall(Check, {Klass, LeftValue}), Accepted, Fallback);
  B.SetInsertPoint(Accepted);
  B.CreateBr(Merge);
  B.SetInsertPoint(Right);
  auto *RightValue = B.CreateSelect(F->getArg(2), C, F->getArg(1));
  B.CreateBr(Merge);
  B.SetInsertPoint(Fallback);
  B.CreateRet(ConstantPointerNull::get(cast<PointerType>(F->getReturnType())));
  B.SetInsertPoint(Merge);
  auto *Root = B.CreatePHI(F->getReturnType(), 2);
  Root->addIncoming(LeftValue, Accepted);
  Root->addIncoming(RightValue, Right);
  auto *Return = B.CreateRet(Root);
  ASSERT_FALSE(verifyFunction(*F));
  DominatorTree DT(*F);
  JavaType T = queryAt(Root, Return, DT);
  EXPECT_EQ(T.Klass, 5U);
  EXPECT_FALSE(T.Exact);
}

TEST_F(JavaBaseTypeTest, DeepTypedChainDoesNotUseTheCallStack) {
  constexpr unsigned Depth = 20000;
  Value *Root = typedSelectChain(Depth);
  B.CreateRet(Root);
  ASSERT_FALSE(verifyFunction(*F));
  JavaType T = query(Root);
  EXPECT_EQ(T.Klass, 5U);
  EXPECT_FALSE(T.Exact);
  EXPECT_LE(CommonSuperQueries, Depth);
}

TEST_F(JavaBaseTypeTest, ShortCircuitDoesNotCacheUnfinishedSibling) {
  auto *A = B.CreatePHI(F->getReturnType(), 2);
  auto *C = B.CreatePHI(F->getReturnType(), 2);
  A->addIncoming(seed(0, 9, true), Entry);
  A->addIncoming(C, Loop);
  C->addIncoming(seed(1, 22, true), Entry);
  C->addIncoming(A, Loop);
  auto *Fork = BasicBlock::Create(Context, "fork", F);
  auto *Guard = BasicBlock::Create(Context, "guard", F);
  auto *Accepted = BasicBlock::Create(Context, "accepted", F);
  auto *Right = BasicBlock::Create(Context, "right", F);
  auto *Fallback = BasicBlock::Create(Context, "fallback", F);
  auto *Merge = BasicBlock::Create(Context, "merge", F);
  B.CreateCondBr(F->getArg(2), Loop, Fork);
  B.SetInsertPoint(Fork);
  auto *Null = ConstantPointerNull::get(cast<PointerType>(F->getReturnType()));
  B.CreateCondBr(B.CreateICmpEQ(F->getArg(3), Null), Guard, Right);
  B.SetInsertPoint(Guard);
  // The first base query stops at the unknown argument, leaving A pending.
  auto *LeftValue = B.CreateSelect(F->getArg(2), F->getArg(3), A);
  auto *RawPtr = PointerType::get(Context, 0);
  FunctionCallee Check = M.getOrInsertFunction(
      "jeandle.check_instanceof", B.getInt1Ty(), RawPtr, F->getReturnType());
  auto *Klass = ConstantExpr::getIntToPtr(B.getInt64(9), RawPtr);
  B.CreateCondBr(B.CreateCall(Check, {Klass, LeftValue}), Accepted, Fallback);
  B.SetInsertPoint(Accepted);
  B.CreateBr(Merge);
  B.SetInsertPoint(Right);
  auto *RightValue = B.CreateSelect(F->getArg(2), C, F->getArg(1));
  B.CreateBr(Merge);
  B.SetInsertPoint(Fallback);
  B.CreateRet(Null);
  B.SetInsertPoint(Merge);
  auto *Root = B.CreatePHI(F->getReturnType(), 2);
  Root->addIncoming(LeftValue, Accepted);
  Root->addIncoming(RightValue, Right);
  auto *Return = B.CreateRet(Root);
  ASSERT_FALSE(verifyFunction(*F));
  DominatorTree DT(*F);
  JavaType T = queryAt(Root, Return, DT);
  // C still needs the completed union of both cycle seeds, not an unknown
  // cached for every node seen during the first query.
  EXPECT_EQ(T.Klass, 5U);
  EXPECT_FALSE(T.Exact);
}

TEST_F(JavaBaseTypeTest, CycleRetainsOnlyCommonInterfaces) {
  VMCallbacks CB = *getVMCallbacks();
  CB.IsInterface = [](uintptr_t K) { return K == 7 || K == 8; };
  CB.GetSecondarySupers = [](uintptr_t K) {
    if (K == 9)
      return std::vector<uintptr_t>{7, 8};
    if (K == 22)
      return std::vector<uintptr_t>{7};
    return std::vector<uintptr_t>{};
  };
  registerVMCallbacks(CB);
  auto *A = B.CreatePHI(F->getReturnType(), 2);
  auto *C = B.CreatePHI(F->getReturnType(), 2);
  A->addIncoming(seed(0, 9, true), Entry);
  A->addIncoming(C, Loop);
  C->addIncoming(seed(1, 22, true), Entry);
  C->addIncoming(A, Loop);
  JavaType T = query(A);
  EXPECT_EQ(T.Klass, 5U);
  EXPECT_TRUE(T.Interfaces.contains(7));
  EXPECT_FALSE(T.Interfaces.contains(8));
  seed(1, 33, true);
  EXPECT_TRUE(query(C).Interfaces.empty());
}

TEST_F(JavaBaseTypeTest, CycleWithMixedExactSeedsStaysInexact) {
  auto *A = B.CreatePHI(F->getReturnType(), 2);
  auto *C = B.CreatePHI(F->getReturnType(), 2);
  A->addIncoming(seed(0, 9, true), Entry);
  A->addIncoming(C, Loop);
  C->addIncoming(seed(1, 9), Entry);
  C->addIncoming(A, Loop);
  JavaType T = query(A);
  EXPECT_EQ(T.Klass, 9U);
  EXPECT_FALSE(T.Exact);
  EXPECT_FALSE(query(C).Exact);
}

TEST_F(JavaBaseTypeTest, CycleThroughSelectCastsAndFreezeStaysUnknown) {
  auto *P = B.CreatePHI(F->getReturnType(), 2);
  P->addIncoming(seed(0, 9, true), Entry);
  auto *Raw = B.CreateAddrSpaceCast(P, PointerType::get(Context, 0));
  auto *Oop = B.CreateAddrSpaceCast(Raw, F->getReturnType());
  auto *Frozen = B.CreateFreeze(Oop);
  auto *Selected = B.CreateSelect(F->getArg(2), Frozen, seed(1, 22, true));
  P->addIncoming(Selected, Loop);
  EXPECT_TRUE(query(P).isUnknown());
  EXPECT_TRUE(query(Selected).isUnknown());
}

TEST_F(JavaBaseTypeTest, SeedlessCycleAndIncompletePhiStayUnknown) {
  auto *A = B.CreatePHI(F->getReturnType(), 1);
  auto *C = B.CreatePHI(F->getReturnType(), 1);
  A->addIncoming(C, Loop);
  C->addIncoming(A, Loop);
  EXPECT_TRUE(query(A).isUnknown());
  auto *Mixed =
      B.CreateSelect(F->getArg(2), seed(0, 9, true), B.CreateFreeze(A));
  EXPECT_TRUE(query(Mixed).isUnknown());
  auto *Incomplete = B.CreatePHI(F->getReturnType(), 0);
  EXPECT_TRUE(query(Incomplete).isUnknown());
  auto *WithIncomplete = B.CreateSelect(F->getArg(2), F->getArg(0), Incomplete);
  EXPECT_TRUE(query(WithIncomplete).isUnknown());
  Incomplete->addIncoming(F->getArg(0), Entry);
  EXPECT_EQ(query(WithIncomplete).Klass, 9U);
}

TEST_F(JavaBaseTypeTest, FreezeOutsideUnseededCycleMemberStaysUnknown) {
  Value *Seed = seed(0, 9, true);
  auto *A = B.CreatePHI(F->getReturnType(), 2);
  auto *C = B.CreatePHI(F->getReturnType(), 2);
  auto *Poisoned =
      SelectInst::Create(PoisonValue::get(B.getInt1Ty()), Seed,
                         seed(1, 9, true), "poisoned", Entry->getTerminator());
  A->addIncoming(Poisoned, Entry);
  A->addIncoming(C, Loop);
  C->addIncoming(A, Loop);
  C->addIncoming(C, Loop);
  auto *Mixed = B.CreateSelect(F->getArg(2), B.CreateFreeze(A), Seed);
  EXPECT_TRUE(query(Mixed).isUnknown());
}

TEST_F(JavaBaseTypeTest, SelectCycleJoinsExternalSeeds) {
  registerCommonInterfaceCallbacks();
  for (auto &Arg : F->args())
    Arg.addAttr(Attribute::NoUndef);
  auto *A = B.CreatePHI(F->getReturnType(), 2, "a");
  auto *C = B.CreatePHI(F->getReturnType(), 2, "c");
  auto *S = B.CreateSelect(F->getArg(2), C, seed(1, 22, true));
  A->addIncoming(seed(0, 9, true), Entry);
  A->addIncoming(S, Loop);
  C->addIncoming(seed(3, 22, true), Entry);
  C->addIncoming(A, Loop);
  auto *Exit = BasicBlock::Create(Context, "exit", F);
  auto *Again = B.CreateCall(M.getOrInsertFunction("iterate", B.getInt1Ty()));
  Again->addRetAttr(Attribute::NoUndef);
  B.CreateCondBr(Again, Loop, Exit);
  B.SetInsertPoint(Exit);
  auto *W = B.CreateSelect(F->getArg(2), A, F->getArg(0));
  auto *Return = B.CreateRet(W);
  ASSERT_FALSE(verifyFunction(*F));
  DominatorTree DT(*F);
  JavaType T = query(A);
  EXPECT_EQ(T.Klass, 5U);
  EXPECT_FALSE(T.Exact);
  EXPECT_TRUE(T.Interfaces.contains(7));
  JavaType TW = queryAt(W, Return, DT);
  EXPECT_EQ(TW.Klass, 5U);
  EXPECT_TRUE(TW.Interfaces.contains(7));
  // With only exact 9 seeds the whole cycle keeps the exact type.
  seed(1, 9, true);
  seed(3, 9, true);
  JavaType Same = query(A);
  EXPECT_EQ(Same.Klass, 9U);
  EXPECT_TRUE(Same.Exact);
}

TEST_F(JavaBaseTypeTest, PhiCycleWithoutDirectSeedJoinsCycleSeeds) {
  registerCommonInterfaceCallbacks();
  for (auto &Arg : F->args())
    Arg.addAttr(Attribute::NoUndef);
  auto *P = B.CreatePHI(F->getReturnType(), 2, "p");
  auto *R = B.CreatePHI(F->getReturnType(), 2, "r");
  auto *Left = BasicBlock::Create(Context, "left", F);
  auto *Right = BasicBlock::Create(Context, "right", F);
  auto *Latch = BasicBlock::Create(Context, "latch", F);
  auto *Exit = BasicBlock::Create(Context, "exit", F);
  auto *Pick = B.CreateICmpNE(
      F->getArg(3),
      ConstantPointerNull::get(cast<PointerType>(F->getReturnType())));
  B.CreateCondBr(Pick, Left, Right);
  B.SetInsertPoint(Left);
  B.CreateBr(Latch);
  B.SetInsertPoint(Right);
  B.CreateBr(Latch);
  B.SetInsertPoint(Latch);
  // Q only merges cycle members; its type still follows the seeds entering
  // the cycle through P and R.
  auto *Q = B.CreatePHI(F->getReturnType(), 2, "q");
  Q->addIncoming(P, Left);
  Q->addIncoming(R, Right);
  P->addIncoming(seed(0, 9, true), Entry);
  P->addIncoming(Q, Latch);
  R->addIncoming(seed(1, 22, true), Entry);
  R->addIncoming(P, Latch);
  auto *W = B.CreateSelect(F->getArg(2), Q, F->getArg(0));
  auto *Mark = B.CreateCall(
      M.getOrInsertFunction("observe", B.getVoidTy(), F->getReturnType()), {W});
  auto *Again = B.CreateCall(M.getOrInsertFunction("iterate", B.getInt1Ty()));
  Again->addRetAttr(Attribute::NoUndef);
  B.CreateCondBr(Again, Loop, Exit);
  B.SetInsertPoint(Exit);
  B.CreateRet(P);
  ASSERT_FALSE(verifyFunction(*F));
  DominatorTree DT(*F);
  JavaType T = query(Q);
  EXPECT_EQ(T.Klass, 5U);
  EXPECT_FALSE(T.Exact);
  EXPECT_TRUE(T.Interfaces.contains(7));
  JavaType TW = queryAt(W, Mark, DT);
  EXPECT_EQ(TW.Klass, 5U);
  EXPECT_TRUE(TW.Interfaces.contains(7));
}

TEST_F(JavaBaseTypeTest, TypeCheckEliminationFoldsCyclicPhiCheck) {
  VMCallbacks CB = *getVMCallbacks();
  CB.IsInterface = [](uintptr_t K) { return K == 7; };
  CB.GetSecondarySupers = [](uintptr_t K) {
    return (K == 9 || K == 22) ? std::vector<uintptr_t>{7}
                               : std::vector<uintptr_t>{};
  };
  CB.IsObjectKlass = [](uintptr_t K) { return K == 5; };
  CB.IsSubtype = [](uintptr_t A, uintptr_t B) {
    return A == B || B == 5 || (B == 7 && (A == 9 || A == 22));
  };
  registerVMCallbacks(CB);
  F->getArg(0)->addAttr(Attribute::NonNull);
  F->getArg(1)->addAttr(Attribute::NonNull);
  for (auto &Arg : F->args())
    Arg.addAttr(Attribute::NoUndef);
  auto *P = B.CreatePHI(F->getReturnType(), 2, "p");
  auto *R = B.CreatePHI(F->getReturnType(), 2, "r");
  auto *Left = BasicBlock::Create(Context, "left", F);
  auto *Right = BasicBlock::Create(Context, "right", F);
  auto *Latch = BasicBlock::Create(Context, "latch", F);
  auto *Exit = BasicBlock::Create(Context, "exit", F);
  auto *Pick = B.CreateICmpNE(
      F->getArg(3),
      ConstantPointerNull::get(cast<PointerType>(F->getReturnType())));
  B.CreateCondBr(Pick, Left, Right);
  B.SetInsertPoint(Left);
  B.CreateBr(Latch);
  B.SetInsertPoint(Right);
  B.CreateBr(Latch);
  B.SetInsertPoint(Latch);
  auto *Q = B.CreatePHI(F->getReturnType(), 2, "q");
  Q->addIncoming(P, Left);
  Q->addIncoming(R, Right);
  P->addIncoming(seed(0, 9, true), Entry);
  P->addIncoming(Q, Latch);
  R->addIncoming(seed(1, 22, true), Entry);
  R->addIncoming(P, Latch);
  auto *W = B.CreateSelect(F->getArg(2), Q, F->getArg(0));
  auto *Mark = B.CreateCall(
      M.getOrInsertFunction("observe", B.getVoidTy(), F->getReturnType()), {W});
  auto *Again = B.CreateCall(M.getOrInsertFunction("iterate", B.getInt1Ty()));
  Again->addRetAttr(Attribute::NoUndef);
  B.CreateCondBr(Again, Loop, Exit);
  B.SetInsertPoint(Exit);
  B.CreateRet(P);
  ASSERT_FALSE(verifyFunction(*F));
  B.SetInsertPoint(Mark);
  auto CheckFn =
      M.getOrInsertFunction("jeandle.check_instanceof", B.getInt1Ty(),
                            PointerType::get(Context, 0), F->getReturnType());
  auto *Check = B.CreateCall(
      CheckFn,
      {ConstantExpr::getIntToPtr(B.getInt64(7), PointerType::get(Context, 0)),
       W});
  Check->addParamAttr(1, Attribute::NonNull);
  auto *Use = B.CreateCall(
      M.getOrInsertFunction("consume", B.getVoidTy(), B.getInt1Ty()), {Check});
  M.getOrInsertNamedMetadata("java-method-compilation");
  ASSERT_FALSE(verifyFunction(*F));
  FunctionAnalysisManager FAM;
  FAM.registerPass([] { return PassInstrumentationAnalysis(); });
  FAM.registerPass([] { return TargetIRAnalysis(); });
  FAM.registerPass([] { return AssumptionAnalysis(); });
  FAM.registerPass([] { return DominatorTreeAnalysis(); });
  FAM.registerPass([] { return LazyValueAnalysis(); });
  TypeCheckElimination().run(*F, FAM);
  auto *Folded = dyn_cast<ConstantInt>(Use->getArgOperand(0));
  ASSERT_NE(Folded, nullptr);
  EXPECT_TRUE(Folded->isOne());
}

TEST_F(JavaBaseTypeTest, PoisonedCycleSeedFreezeStaysUnknown) {
  // Legal closed CFG: header and latch are separate blocks, and the pick
  // choosing the frozen member is independent of the loop exit condition.
  Value *Seed = seed(0, 9, true);
  auto *OtherSeed = seed(1, 9, true);
  auto *Poisoned =
      SelectInst::Create(PoisonValue::get(B.getInt1Ty()), Seed, OtherSeed,
                         "poisoned", Entry->getTerminator());
  auto *A = B.CreatePHI(F->getReturnType(), 2, "a");
  auto *Latch = BasicBlock::Create(Context, "latch", F);
  auto *Exit = BasicBlock::Create(Context, "exit", F);
  B.CreateCondBr(F->getArg(2), Latch, Exit);
  B.SetInsertPoint(Latch);
  auto *C = B.CreatePHI(F->getReturnType(), 2, "c");
  C->addIncoming(A, Loop);
  C->addIncoming(C, Latch);
  B.CreateCondBr(F->getArg(2), Latch, Loop);
  A->addIncoming(Poisoned, Entry);
  A->addIncoming(C, Latch);
  B.SetInsertPoint(Exit);
  auto *Pick = B.CreateICmpNE(
      F->getArg(3),
      ConstantPointerNull::get(cast<PointerType>(F->getReturnType())));
  auto *Mixed = B.CreateSelect(Pick, B.CreateFreeze(A), Seed);
  B.CreateRet(Mixed);
  ASSERT_FALSE(verifyFunction(*F));
  // The cycle seed is a select with a poison condition: freezing the member
  // can expose an arbitrary reference, so the query must stay unknown even
  // though every seed carries exact 9.
  EXPECT_TRUE(query(Mixed).isUnknown());
}

TEST_F(JavaBaseTypeTest, BoundedSharedCyclicDagCountsCommonSuperQueries) {
  auto *A = B.CreatePHI(F->getReturnType(), 2, "a");
  auto *C = B.CreatePHI(F->getReturnType(), 2, "c");
  A->addIncoming(seed(0, 9, true), Entry);
  A->addIncoming(A, Loop);
  C->addIncoming(seed(1, 22, true), Entry);
  C->addIncoming(C, Loop);
  Value *Left = A;
  Value *Right = C;
  constexpr unsigned Depth = 18;
  for (unsigned I = 0; I != Depth; ++I) {
    auto *L = B.CreateSelect(F->getArg(2), Left, Right);
    auto *R = B.CreateSelect(F->getArg(2), Right, Left);
    Left = L;
    Right = R;
  }
  auto *Exit = BasicBlock::Create(Context, "exit", F);
  B.CreateCondBr(F->getArg(2), Loop, Exit);
  B.SetInsertPoint(Exit);
  B.CreateRet(Left);
  ASSERT_FALSE(verifyFunction(*F));
  JavaType T = query(Left);
  EXPECT_EQ(T.Klass, 5U);
  // The self-cycled seeds complete once and the DAG above them joins cached
  // inputs; without the completion cache each level re-expanded both arms
  // (2^Depth CommonSuperKlass calls on the old recursion).
  EXPECT_LE(CommonSuperQueries, 4 * Depth);
}

TEST_F(JavaBaseTypeTest, ZeroCommonSuperKlassStaysUnknown) {
  VMCallbacks CB = *getVMCallbacks();
  CB.GetCommonSuperKlass = [](uintptr_t X, uintptr_t Y) {
    ++CommonSuperQueries;
    return X == Y ? X : uintptr_t(0);
  };
  registerVMCallbacks(CB);
  auto *A = B.CreatePHI(F->getReturnType(), 2);
  auto *C = B.CreatePHI(F->getReturnType(), 2);
  A->addIncoming(seed(0, 9, true), Entry);
  A->addIncoming(C, Loop);
  C->addIncoming(seed(1, 22, true), Entry);
  C->addIncoming(A, Loop);
  auto *Exit = BasicBlock::Create(Context, "exit", F);
  B.CreateCondBr(F->getArg(2), Loop, Exit);
  B.SetInsertPoint(Exit);
  auto *S = B.CreateSelect(F->getArg(2), A, C);
  B.CreateRet(A);
  ASSERT_FALSE(verifyFunction(*F));
  EXPECT_TRUE(query(A).isUnknown());
  EXPECT_TRUE(query(S).isUnknown());
}

TEST_F(JavaBaseTypeTest, CallReturnAndLoadMetadataLeaves) {
  auto Callee = M.getOrInsertFunction("leaf", F->getReturnType());
  auto *Call = B.CreateCall(Callee);
  Call->addRetAttr(Attribute::get(Context, "java-klass", "9"));
  Call->addRetAttr(Attribute::get(Context, "java-klass-exact"));
  auto *Load = B.CreateLoad(F->getReturnType(), F->getArg(3));
  Load->setMetadata("java-klass", MDNode::get(Context, ConstantAsMetadata::get(
                                                           B.getInt64(22))));
  Load->setMetadata("java-klass-exact", MDNode::get(Context, {}));
  auto *S = B.CreateSelect(F->getArg(2), Call, Load);
  B.CreateRet(S);
  ASSERT_FALSE(verifyFunction(*F));
  EXPECT_EQ(query(Call).Klass, 9U);
  EXPECT_TRUE(query(Call).Exact);
  EXPECT_EQ(query(Load).Klass, 22U);
  EXPECT_TRUE(query(Load).Exact);
  EXPECT_EQ(query(S).Klass, 5U);
}

TEST_F(JavaBaseTypeTest, InvokeReturnAttributeLeaf) {
  auto Callee = M.getOrInsertFunction("invokee", F->getReturnType());
  F->setPersonalityFn(cast<Function>(
      M.getOrInsertFunction("__gxx_personality_v0", B.getInt32Ty())
          .getCallee()));
  auto *Unwind = BasicBlock::Create(Context, "unwind", F);
  Entry->getTerminator()->eraseFromParent();
  B.SetInsertPoint(Entry);
  auto *Invoke = B.CreateInvoke(Callee, Loop, Unwind);
  Invoke->addRetAttr(Attribute::get(Context, "java-klass", "9"));
  Invoke->addRetAttr(Attribute::get(Context, "java-klass-exact"));
  B.SetInsertPoint(Loop);
  B.CreateRet(Invoke);
  B.SetInsertPoint(Unwind);
  auto *Pad = B.CreateLandingPad(PointerType::get(Context, 0), 0);
  Pad->setCleanup(true);
  B.CreateResume(Pad);
  ASSERT_FALSE(verifyFunction(*F));
  JavaType T = query(Invoke);
  EXPECT_EQ(T.Klass, 9U);
  EXPECT_TRUE(T.Exact);
}

TEST_F(JavaBaseTypeTest, OopHandleLoadQueriesExactKlass) {
  VMCallbacks CB = *getVMCallbacks();
  CB.GetOopKlass = [](int Id) { return Id == 3 ? uintptr_t(9) : uintptr_t(0); };
  registerVMCallbacks(CB);
  auto *Handle =
      new GlobalVariable(M, F->getReturnType(), false,
                         GlobalValue::ExternalLinkage, nullptr, "oop_handle_3");
  auto *Load = B.CreateLoad(F->getReturnType(), Handle);
  auto *Exit = BasicBlock::Create(Context, "exit", F);
  B.CreateCondBr(F->getArg(2), Loop, Exit);
  B.SetInsertPoint(Exit);
  B.CreateRet(Load);
  ASSERT_FALSE(verifyFunction(*F));
  JavaType T = query(Load);
  EXPECT_EQ(T.Klass, 9U);
  EXPECT_TRUE(T.Exact);
}

TEST_F(JavaBaseTypeTest, RootFreezeRequiresDefinedOperand) {
  checkPattern("%f = freeze ptr addrspace(1) %maybe\n"
               "ret ptr addrspace(1) %f",
               0, false);
  checkPattern("%f = freeze ptr addrspace(1) %a\n"
               "ret ptr addrspace(1) %f",
               9);
}

TEST_F(JavaBaseTypeTest, RootFreezeOfPoisonedCycleStaysUnknown) {
  checkPattern(R"IR(
    entry:
      br label %loop
    loop:
      %p = phi ptr addrspace(1) [%a, %entry], [%s, %loop]
      %i = phi i32 [0, %entry], [%next, %loop]
      %s = select i1 poison, ptr addrspace(1) %p, ptr addrspace(1) %a
      %next = add i32 %i, 1
      %again = icmp ult i32 %next, 2
      br i1 %again, label %loop, label %exit
    exit:
      %f = freeze ptr addrspace(1) %p
      ret ptr addrspace(1) %f
  )IR",
               0, false);
}

TEST_F(JavaBaseTypeTest, FreezeDoesNotInheritOperandGuard) {
  checkPattern(R"IR(
    entry:
      %check = call i1 @jeandle.check_instanceof(ptr inttoptr (i64 9 to ptr),
                                                ptr addrspace(1) %unknown)
      br i1 %check, label %accepted, label %exit
    exit:
      ret ptr addrspace(1) null
    accepted:
      %f = freeze ptr addrspace(1) %unknown
      ret ptr addrspace(1) %f
  )IR",
               0, false);
}

TEST_F(JavaBaseTypeTest, FreezeRetainsItsOwnGuard) {
  checkPattern(R"IR(
    entry:
      %f = freeze ptr addrspace(1) %unknown
      %check = call i1 @jeandle.check_instanceof(ptr inttoptr (i64 9 to ptr),
                                                ptr addrspace(1) %f)
      br i1 %check, label %accepted, label %exit
    exit:
      ret ptr addrspace(1) null
    accepted:
      ret ptr addrspace(1) %f
  )IR",
               0, false, 9, false);
}

TEST_F(JavaBaseTypeTest, NestedFreezeOfDefinedLoadRetainsType) {
  checkPattern(R"IR(
    %v = load ptr addrspace(1), ptr %slot, !noundef !0,
              !java-klass !1, !java-klass-exact !0
    %f = freeze ptr addrspace(1) %v
    %r = select i1 %pick, ptr addrspace(1) %f, ptr addrspace(1) %a
    ret ptr addrspace(1) %r
  )IR",
               9);
  checkPattern(R"IR(
    %v = load ptr addrspace(1), ptr %slot,
              !java-klass !1, !java-klass-exact !0
    %f = freeze ptr addrspace(1) %v
    %r = select i1 %pick, ptr addrspace(1) %f, ptr addrspace(1) %a
    ret ptr addrspace(1) %r
  )IR",
               0, false);
}

TEST_F(JavaBaseTypeTest, NestedFreezeOfDefinedSelfPhiRetainsType) {
  checkPattern(R"IR(
    entry:
      br label %loop
    loop:
      %p = phi ptr addrspace(1) [%a, %entry], [%p, %loop]
      br i1 %pick, label %loop, label %exit
    exit:
      %f = freeze ptr addrspace(1) %p
      %r = select i1 %pick, ptr addrspace(1) %f, ptr addrspace(1) %a
      ret ptr addrspace(1) %r
  )IR",
               9);
}

TEST_F(JavaBaseTypeTest, NestedFreezeOfDefinedMutualPhisRetainsType) {
  checkPattern(R"IR(
    entry:
      br label %loop
    loop:
      %p = phi ptr addrspace(1) [%a, %entry], [%q, %loop]
      %q = phi ptr addrspace(1) [%b, %entry], [%p, %loop]
      br i1 %pick, label %loop, label %exit
    exit:
      %f = freeze ptr addrspace(1) %p
      %r = select i1 %pick, ptr addrspace(1) %f, ptr addrspace(1) %a
      ret ptr addrspace(1) %r
  )IR",
               9);
}

TEST_F(JavaBaseTypeTest, DefinedCycleContainingFreezeRetainsType) {
  checkPattern(R"IR(
    entry:
      br label %loop
    loop:
      %p = phi ptr addrspace(1) [%a, %entry], [%f, %loop]
      %f = freeze ptr addrspace(1) %p
      br i1 %pick, label %loop, label %exit
    exit:
      ret ptr addrspace(1) %p
  )IR",
               9);
}

TEST_F(JavaBaseTypeTest, NestedFreezeOfICmpSelectRetainsType) {
  checkPattern(R"IR(
    %c = icmp eq i32 %x, 0
    %s = select i1 %c, ptr addrspace(1) %a, ptr addrspace(1) %b
    %f = freeze ptr addrspace(1) %s
    %r = select i1 %pick, ptr addrspace(1) %f, ptr addrspace(1) %a
    ret ptr addrspace(1) %r
  )IR",
               9);
}

TEST_F(JavaBaseTypeTest, NestedFreezeOfPoisonGeneratingICmpStaysUnknown) {
  checkPattern(R"IR(
    %c = icmp samesign eq i32 %x, %y
    %s = select i1 %c, ptr addrspace(1) %a, ptr addrspace(1) %b
    %f = freeze ptr addrspace(1) %s
    %r = select i1 %pick, ptr addrspace(1) %f, ptr addrspace(1) %a
    ret ptr addrspace(1) %r
  )IR",
               0, false);
}

TEST_F(JavaBaseTypeTest, NestedFreezeOfArithmeticConditionChecksPoisonFlags) {
  checkPattern(R"IR(
    %sum = add i32 %x, %y
    %c = icmp eq i32 %sum, 0
    %s = select i1 %c, ptr addrspace(1) %a, ptr addrspace(1) %b
    %f = freeze ptr addrspace(1) %s
    %r = select i1 %pick, ptr addrspace(1) %f, ptr addrspace(1) %a
    ret ptr addrspace(1) %r
  )IR",
               9);
  checkPattern(R"IR(
    %sum = add nsw i32 %x, %y
    %c = icmp eq i32 %sum, 0
    %s = select i1 %c, ptr addrspace(1) %a, ptr addrspace(1) %b
    %f = freeze ptr addrspace(1) %s
    %r = select i1 %pick, ptr addrspace(1) %f, ptr addrspace(1) %a
    ret ptr addrspace(1) %r
  )IR",
               0, false);
}

TEST_F(JavaBaseTypeTest, NestedFreezeOfAddressSpaceCastStaysConservative) {
  checkPattern(R"IR(
    %cast = addrspacecast ptr addrspace(1) %a to ptr addrspace(3)
    %f = freeze ptr addrspace(3) %cast
    %r = addrspacecast ptr addrspace(3) %f to ptr addrspace(1)
    ret ptr addrspace(1) %r
  )IR",
               0, false);
}

TEST_F(JavaBaseTypeTest, ReturnedCallNestedInSelectRetainsType) {
  checkPattern(R"IR(
    %v = call ptr addrspace(1) @identity(ptr addrspace(1) %a)
    %r = select i1 %pick, ptr addrspace(1) %v, ptr addrspace(1) %b
    ret ptr addrspace(1) %r
  )IR",
               9);
}

TEST_F(JavaBaseTypeTest, ReturnedCallRetainsItsOwnTypeSeed) {
  checkPattern(R"IR(
    %v = call "java-klass"="9" "java-klass-exact" ptr addrspace(1)
              @identity(ptr addrspace(1) %unknown)
    %r = select i1 %pick, ptr addrspace(1) %v, ptr addrspace(1) %a
    ret ptr addrspace(1) %r
  )IR",
               9);
  checkPattern(R"IR(
    %v = call "java-klass"="9" "java-klass-exact" ptr addrspace(1)
              @identity(ptr addrspace(1) %unknown)
    %g = getelementptr i8, ptr addrspace(1) %v, i64 0
    ret ptr addrspace(1) %g
  )IR",
               9);
}

TEST_F(JavaBaseTypeTest, FreezeOfReturnedCallNeedsDefinedResult) {
  checkPattern(R"IR(
    %v = call nonnull ptr addrspace(1) @identity(ptr addrspace(1) %a)
    %f = freeze ptr addrspace(1) %v
    ret ptr addrspace(1) %f
  )IR",
               0, false);
  checkPattern(R"IR(
    %v = call ptr addrspace(1) @nonnull_identity(ptr addrspace(1) %a)
    %f = freeze ptr addrspace(1) %v
    ret ptr addrspace(1) %f
  )IR",
               0, false);
  checkPattern(R"IR(
    %v = call noundef ptr addrspace(1) @identity(ptr addrspace(1) %a)
    %f = freeze ptr addrspace(1) %v
    ret ptr addrspace(1) %f
  )IR",
               9);
}

TEST_F(JavaBaseTypeTest, ZeroGepNestedInSelectRetainsType) {
  checkPattern(R"IR(
    %g = getelementptr i8, ptr addrspace(1) %a, i64 0
    %r = select i1 %pick, ptr addrspace(1) %g, ptr addrspace(1) %a
    ret ptr addrspace(1) %r
  )IR",
               9);
}

TEST_F(JavaBaseTypeTest, ZeroGepNestedInPhiRetainsType) {
  checkPattern(R"IR(
    entry:
      br i1 %pick, label %left, label %right
    left:
      %g = getelementptr i8, ptr addrspace(1) %a, i64 0
      br label %merge
    right:
      br label %merge
    merge:
      %p = phi ptr addrspace(1) [%g, %left], [%b, %right]
      ret ptr addrspace(1) %p
  )IR",
               9);
}

TEST_F(JavaBaseTypeTest, ZeroGepInSelectCycleRetainsType) {
  checkPattern(R"IR(
    entry:
      br label %loop
    loop:
      %p = phi ptr addrspace(1) [%a, %entry], [%s, %loop]
      %g = getelementptr i8, ptr addrspace(1) %p, i64 0
      %s = select i1 %pick, ptr addrspace(1) %g, ptr addrspace(1) %b
      br i1 %pick, label %loop, label %exit
    exit:
      ret ptr addrspace(1) %p
  )IR",
               9);
}

TEST_F(JavaBaseTypeTest, NonzeroGepDoesNotForwardObjectType) {
  checkPattern(R"IR(
    %g = getelementptr i8, ptr addrspace(1) %a, i64 1
    %r = select i1 %pick, ptr addrspace(1) %g, ptr addrspace(1) %a
    ret ptr addrspace(1) %r
  )IR",
               0, false);
}

TEST_F(JavaBaseTypeTest, ConstantSelectIgnoresUnselectedArm) {
  checkPattern(R"IR(
    %s = select i1 true, ptr addrspace(1) %a, ptr addrspace(1) %unknown
    ret ptr addrspace(1) %s
  )IR",
               9);
  checkPattern(R"IR(
    %s = select i1 false, ptr addrspace(1) %unknown, ptr addrspace(1) %b
    ret ptr addrspace(1) %s
  )IR",
               9);
  checkPattern(R"IR(
    %s = select i1 true, ptr addrspace(1) %a, ptr addrspace(1) poison
    %f = freeze ptr addrspace(1) %s
    %r = select i1 %pick, ptr addrspace(1) %f, ptr addrspace(1) %b
    ret ptr addrspace(1) %r
  )IR",
               9);
  checkPattern(R"IR(
    %s = select i1 false, ptr addrspace(1) %a, ptr addrspace(1) %unknown
    ret ptr addrspace(1) %s
  )IR",
               0, false);
}

TEST_F(JavaBaseTypeTest, DeepDefinedChainThroughFreezeRetainsType) {
  constexpr unsigned Depth = 20000;
  for (auto &Arg : F->args())
    Arg.addAttr(Attribute::NoUndef);
  Value *Root = typedSelectChain(Depth);
  Value *Frozen = B.CreateFreeze(Root);
  Value *Result = B.CreateSelect(F->getArg(2), Frozen, F->getArg(0));
  B.CreateRet(Result);
  ASSERT_FALSE(verifyFunction(*F));
  JavaType T = query(Result);
  EXPECT_EQ(T.Klass, 5U);
  EXPECT_FALSE(T.Exact);
  EXPECT_LE(CommonSuperQueries, Depth + 4);
}

TEST_F(JavaBaseTypeTest, WidenedGuardsUseTheRealValueDomain) {
  // sext i1 -> i8 has domain {0,-1}: `sle %s, 0` is always true, so the exit
  // edge carries no check outcome and must stay unknown. An assumed {0,1}
  // domain would wrongly install a failed-check exclusion on the exit edge.
  checkPattern(R"IR(
    entry:
      %check = call i1 @jeandle.check_instanceof(ptr inttoptr (i64 9 to ptr),
                                                ptr addrspace(1) %unknown)
      %s = sext i1 %check to i8
      %t = icmp sle i8 %s, 0
      br i1 %t, label %always, label %exit
    always:
      ret ptr addrspace(1) null
    exit:
      ret ptr addrspace(1) %unknown
  )IR",
               0, false, 0, false);
  // The discriminating form still reads correctly: on the eq-zero false edge
  // the check passed, so the klass is recovered there.
  checkPattern(R"IR(
    entry:
      %check = call i1 @jeandle.check_instanceof(ptr inttoptr (i64 9 to ptr),
                                                ptr addrspace(1) %unknown)
      %z = zext i1 %check to i32
      %t = icmp eq i32 %z, 0
      br i1 %t, label %zero, label %exit
    zero:
      ret ptr addrspace(1) null
    exit:
      ret ptr addrspace(1) %unknown
  )IR",
               0, false, 9, false);
  // A constant phi arm outside the traced pair makes the phi check-independent
  // on both outcomes: the no-edge must carry no exclusion.
  checkPattern(R"IR(
    entry:
      %check = call i1 @jeandle.check_instanceof(ptr inttoptr (i64 9 to ptr),
                                                ptr addrspace(1) %unknown)
      %z = zext i1 %check to i8
      br i1 %pick, label %left, label %right
    left:
      br label %merge
    right:
      br label %merge
    merge:
      %p = phi i8 [ %z, %left ], [ 2, %right ]
      %t = icmp eq i8 %p, 1
      br i1 %t, label %yes, label %no
    yes:
      ret ptr addrspace(1) null
    no:
      ret ptr addrspace(1) %unknown
  )IR",
               0, false, 0, false);
}

TEST_F(JavaBaseTypeTest, TypeIntersectKeepsInterfaceExclusions) {
  VMCallbacks CB = *getVMCallbacks();
  CB.IsInterface = [](uintptr_t K) { return K == 7; };
  CB.GetSecondarySupers = [](uintptr_t) { return std::vector<uintptr_t>{}; };
  registerVMCallbacks(CB);
  JavaType Known; // Positive klass without interface knowledge.
  Known.Klass = 9;
  JavaType Guarded; // Failed check against interface 7.
  Guarded.ExcludedKlasses.insert(7);
  JavaType T = typeIntersect(Known, Guarded);
  EXPECT_EQ(T.Klass, 9U);
  EXPECT_TRUE(T.ExcludedKlasses.contains(7));
  // A class exclusion unrelated to the positive klass stays droppable: a
  // value of klass 9 can never be an unrelated class.
  JavaType ClassGuarded;
  ClassGuarded.ExcludedKlasses.insert(22);
  JavaType T2 = typeIntersect(Known, ClassGuarded);
  EXPECT_FALSE(T2.ExcludedKlasses.contains(22));
}

TEST_F(JavaBaseTypeTest, NullAndPoisonArmsAreVacuousUnderTheNonNullContract) {
  auto *Null = ConstantPointerNull::get(cast<PointerType>(F->getReturnType()));
  auto *Exit = BasicBlock::Create(Context, "exit", F);
  auto *P = B.CreatePHI(F->getReturnType(), 2);
  P->addIncoming(Null, Entry);
  P->addIncoming(seed(0, 9, true), Loop);
  B.CreateCondBr(F->getArg(2), Loop, Exit);
  B.SetInsertPoint(Exit);
  B.CreateRet(P);
  ASSERT_FALSE(verifyFunction(*F));
  // The null arm only executes when the value IS null, which the non-null
  // contract excludes: the base query keeps the typed arm.
  EXPECT_EQ(query(P), JavaType(9, true));

  auto *PoisonArm = SelectInst::Create(F->getArg(2), seed(1, 9, true),
                                       PoisonValue::get(F->getReturnType()));
  PoisonArm->insertBefore(Entry->getTerminator());
  EXPECT_EQ(query(PoisonArm), JavaType(9, true));

  // Undef can materialize an arbitrary oop when selected: still absorbing.
  auto *UndefArm = SelectInst::Create(F->getArg(2), seed(3, 9, true),
                                      UndefValue::get(F->getReturnType()));
  UndefArm->insertBefore(Entry->getTerminator());
  EXPECT_TRUE(query(UndefArm).isUnknown());
}

TEST_F(JavaBaseTypeTest, DeadIncomingArmSkipsTheJoin) {
  // The classic lazy-null pattern: y = phi [exact Dog, null] keeps an exact
  // type once null arms are vacuous; the failed instanceof then contradicts
  // that type on the else edge, so y's only live value there is null and the
  // arm is dead for the outer join — x is exactly the other arm's class.
  Value *Dog = seed(0, 9, true);
  Value *Cat = seed(1, 22, true);
  auto *Null = ConstantPointerNull::get(cast<PointerType>(F->getReturnType()));
  auto *RawPtr = PointerType::get(Context, 0);
  FunctionCallee Check = M.getOrInsertFunction(
      "jeandle.check_instanceof", B.getInt1Ty(), RawPtr, F->getReturnType());
  auto *Klass = ConstantExpr::getIntToPtr(B.getInt64(9), RawPtr);

  auto *DogArm = BasicBlock::Create(Context, "dogarm", F);
  auto *NullArm = BasicBlock::Create(Context, "nullarm", F);
  auto *YMerge = BasicBlock::Create(Context, "ymerge", F);
  auto *Passed = BasicBlock::Create(Context, "passed", F);
  auto *ElseArm = BasicBlock::Create(Context, "elsearm", F);
  auto *CatArm = BasicBlock::Create(Context, "catarm", F);
  auto *XMerge = BasicBlock::Create(Context, "xmerge", F);
  B.CreateCondBr(F->getArg(2), DogArm, NullArm);
  B.SetInsertPoint(DogArm);
  B.CreateBr(YMerge);
  B.SetInsertPoint(NullArm);
  B.CreateBr(YMerge);
  B.SetInsertPoint(YMerge);
  auto *Y = B.CreatePHI(F->getReturnType(), 2, "y");
  Y->addIncoming(Dog, DogArm);
  Y->addIncoming(Null, NullArm);
  auto *Chk = B.CreateCall(Check, {Klass, Y});
  B.CreateCondBr(Chk, Passed, ElseArm);
  B.SetInsertPoint(Passed);
  B.CreateRet(Null);
  B.SetInsertPoint(ElseArm);
  B.CreateCondBr(F->getArg(2), CatArm, XMerge);
  B.SetInsertPoint(CatArm);
  B.CreateBr(XMerge);
  B.SetInsertPoint(XMerge);
  auto *X = B.CreatePHI(F->getReturnType(), 2, "x");
  X->addIncoming(Cat, CatArm);
  X->addIncoming(Y, ElseArm);
  auto *Return = B.CreateRet(X);
  ASSERT_FALSE(verifyFunction(*F));

  // The context-insensitive base still joins both arms: LCA(Dog, Cat).
  EXPECT_EQ(query(X), JavaType(5, false));
  // The context query sees the dead arm skipped: y's non-null executions
  // all pass the check, so only the Cat arm reaches the merge.
  DominatorTree DT(*F);
  EXPECT_EQ(queryAt(X, Return, DT), JavaType(22, true));
}

TEST_F(JavaBaseTypeTest, CovariantInterfaceArraysCanOverlap) {
  VMCallbacks CB = *getVMCallbacks();
  CB.IsInterface = [](uintptr_t K) { return K == 7; };
  CB.IsUnverifiedInterface = [](uintptr_t K) {
    return K == 7 || K == 70 || K == 700;
  };
  CB.IsSubtype = [](uintptr_t A, uintptr_t B) {
    return A == B || B == 5 || (A == 22 && (B == 9 || B == 7)) ||
           (A == 220 && (B == 90 || B == 70)) ||
           (A == 2200 && (B == 900 || B == 700));
  };
  registerVMCallbacks(CB);
  EXPECT_FALSE(areKlassesIncompatible(90, false, 70));
  EXPECT_FALSE(areKlassesIncompatible(70, false, 90));
  EXPECT_FALSE(areKlassesIncompatible(900, false, 700));
  EXPECT_FALSE(areKlassesIncompatible(9, false, 7));
  EXPECT_TRUE(areKlassesIncompatible(90, true, 70));
  EXPECT_TRUE(areKlassesIncompatible(80, false, 90));
  EXPECT_FALSE(areKlassesIncompatible(220, true, 70));
  CB.IsUnverifiedInterface = nullptr;
  registerVMCallbacks(CB);
  EXPECT_FALSE(areKlassesIncompatible(90, false, 70));
  EXPECT_TRUE(areKlassesIncompatible(90, true, 70));
}

TEST_F(JavaBaseTypeTest, IntersectRetainsClassAlongsideUnrelatedInterface) {
  VMCallbacks CB = *getVMCallbacks();
  CB.IsInterface = [](uintptr_t K) { return K == 7; };
  CB.IsUnverifiedInterface = CB.IsInterface;
  registerVMCallbacks(CB);
  for (JavaType T : {typeIntersect(JavaType(9, false), JavaType(7, false)),
                     typeIntersect(JavaType(7, false), JavaType(9, false))}) {
    EXPECT_EQ(T.Klass, 9U);
    EXPECT_FALSE(T.Exact);
    EXPECT_TRUE(T.Interfaces.contains(7));
  }
}

TEST_F(JavaBaseTypeTest, InterfaceBoundRetainsClassExclusion) {
  VMCallbacks CB = *getVMCallbacks();
  CB.IsInterface = [](uintptr_t K) { return K == 7; };
  CB.IsUnverifiedInterface = CB.IsInterface;
  registerVMCallbacks(CB);
  JavaType Negative;
  Negative.ExcludedKlasses.insert(9);
  JavaType T = typeIntersect(JavaType(7, false), Negative);
  EXPECT_EQ(T.Klass, 7U);
  EXPECT_TRUE(T.ExcludedKlasses.contains(9));
}

TEST_F(JavaBaseTypeTest, UnionRetainsImplicitAndExplicitExclusion) {
  VMCallbacks CB = *getVMCallbacks();
  CB.IsSubtype = [](uintptr_t A, uintptr_t B) {
    return A == B || B == 5 || (A == 22 && B == 9);
  };
  registerVMCallbacks(CB);
  JavaType Left(9, false);
  Left.ExcludedKlasses.insert(22);
  JavaType Right(33, false);
  EXPECT_TRUE(typeUnion(Left, Right).ExcludedKlasses.contains(22));
  EXPECT_TRUE(typeUnion(Right, Left).ExcludedKlasses.contains(22));
  EXPECT_FALSE(typeUnion(Left, JavaType(22, false)).hasExclusions());
}

TEST_F(JavaBaseTypeTest, KlassLoadsRequireDefinitiveInitializers) {
  auto *RawPtr = PointerType::get(Context, 0);
  auto *Klass = ConstantExpr::getIntToPtr(B.getInt64(9), RawPtr);
  auto MakeLoad = [&](GlobalValue::LinkageTypes Linkage, bool ExternalInit) {
    auto *GV = new GlobalVariable(M, RawPtr, true, Linkage, Klass, "klass_slot",
                                  nullptr, GlobalVariable::NotThreadLocal, 0,
                                  ExternalInit);
    return B.CreateLoad(RawPtr, GV);
  };
  EXPECT_EQ(extractKlassConstant(MakeLoad(GlobalValue::InternalLinkage, false)),
            9U);
  EXPECT_EQ(extractKlassConstant(MakeLoad(GlobalValue::WeakODRLinkage, false)),
            9U);
  EXPECT_EQ(extractKlassConstant(MakeLoad(GlobalValue::WeakAnyLinkage, false)),
            0U);
  EXPECT_EQ(extractKlassConstant(MakeLoad(GlobalValue::ExternalLinkage, true)),
            0U);
}

TEST_F(JavaBaseTypeTest, KlassLoadsDoNotFollowInterposableAliases) {
  auto *RawPtr = PointerType::get(Context, 0);
  auto *Klass = ConstantExpr::getIntToPtr(B.getInt64(9), RawPtr);
  auto *Slot = new GlobalVariable(M, RawPtr, true, GlobalValue::InternalLinkage,
                                  Klass, "klass_slot");
  auto *Strong = GlobalAlias::create(RawPtr, 0, GlobalValue::InternalLinkage,
                                     "local_slot", Slot, &M);
  auto *Weak = GlobalAlias::create(RawPtr, 0, GlobalValue::WeakAnyLinkage,
                                   "weak_slot", Strong, &M);
  auto *Nested =
      GetElementPtrInst::Create(B.getInt8Ty(), Weak, {B.getInt64(0)});
  B.Insert(Nested);
  EXPECT_EQ(extractKlassConstant(B.CreateLoad(RawPtr, Strong)), 9U);
  EXPECT_EQ(extractKlassConstant(B.CreateLoad(RawPtr, Weak)), 0U);
  EXPECT_EQ(extractKlassConstant(B.CreateLoad(RawPtr, Nested)), 0U);
  B.CreateRet(F->getArg(0));
  ASSERT_FALSE(verifyModule(M, &errs()));
}

TEST_F(JavaBaseTypeTest, ReturnedAttributeAndArgumentConstraintsIntersect) {
  checkPattern(R"IR(
    %r = call "java-klass"="5" ptr addrspace(1)
      @identity(ptr addrspace(1) %a)
    %s = select i1 %pick, ptr addrspace(1) %r, ptr addrspace(1) %b
    ret ptr addrspace(1) %s
  )IR",
               9);
  checkPattern(R"IR(
    %r = call "java-klass"="9" "java-klass-exact" ptr addrspace(1)
      @identity(ptr addrspace(1) %unknown)
    ret ptr addrspace(1) %r
  )IR",
               9);
  checkPattern(R"IR(
    entry:
      br label %loop
    loop:
      %p = phi ptr addrspace(1) [ %a, %entry ], [ %r, %loop ]
      %r = call "java-klass"="5" ptr addrspace(1)
        @identity(ptr addrspace(1) %p)
      br i1 %pick, label %loop, label %exit
    exit:
      ret ptr addrspace(1) %r
  )IR",
               9);
}

TEST_F(JavaBaseTypeTest, InvariantGroupIntrinsicsRetainObjectType) {
  Value *A = seed(0, 9, true);
  for (Intrinsic::ID ID :
       {Intrinsic::launder_invariant_group, Intrinsic::strip_invariant_group}) {
    auto *IntrinsicFn =
        Intrinsic::getOrInsertDeclaration(&M, ID, {A->getType()});
    auto *Call = B.CreateCall(IntrinsicFn, {A});
    auto *S = B.CreateSelect(F->getArg(2), Call, A);
    EXPECT_EQ(query(Call), JavaType(9, true));
    EXPECT_EQ(query(S), JavaType(9, true));
  }
}

TEST_F(JavaBaseTypeTest, SeededIdentityCycleUsesDependentRefinement) {
  constexpr unsigned Count = 512;
  Value *Narrow = seed(0, 9);
  auto *Hide = Function::Create(
      FunctionType::get(F->getReturnType(), {F->getReturnType()}, false),
      GlobalValue::InternalLinkage, "hide_type", M);
  IRBuilder<> Helper(BasicBlock::Create(Context, "entry", Hide));
  Helper.CreateRet(Hide->getArg(0));
  IRBuilder<> EntryBuilder(Entry->getTerminator());
  auto *Wide = EntryBuilder.CreateCall(Hide, {Narrow});
  Wide->addRetAttr(Attribute::get(Context, "java-klass", "5"));
  auto *Null = ConstantPointerNull::get(cast<PointerType>(F->getReturnType()));
  auto *Left = BasicBlock::Create(Context, "left", F);
  auto *Right = BasicBlock::Create(Context, "right", F);
  auto *Exit = BasicBlock::Create(Context, "exit", F);
  SmallVector<PHINode *, Count> Phis;
  for (unsigned I = 0; I != Count; ++I)
    Phis.push_back(B.CreatePHI(F->getReturnType(), 3));
  auto Identity =
      M.getOrInsertFunction("identity", F->getReturnType(), F->getReturnType());
  cast<Function>(Identity.getCallee())->addParamAttr(0, Attribute::Returned);
  SmallVector<Value *, Count> Calls;
  for (unsigned I = 0; I != Count; ++I) {
    Value *Input = I + 1 == Count ? B.CreateSelect(F->getArg(2), Phis[0], Wide)
                                  : Phis[I + 1];
    auto *Call = B.CreateCall(Identity, {Input});
    Call->addRetAttr(Attribute::get(Context, "java-klass", "9"));
    Calls.push_back(Call);
  }
  B.CreateCondBr(F->getArg(2), Left, Right);
  B.SetInsertPoint(Left);
  B.CreateBr(Loop);
  B.SetInsertPoint(Right);
  B.CreateCondBr(B.CreateICmpEQ(F->getArg(1), Null), Loop, Exit);
  B.SetInsertPoint(Exit);
  B.CreateRet(Phis[0]);
  for (unsigned I = 0; I != Count; ++I) {
    Phis[I]->addIncoming(Null, Entry);
    Phis[I]->addIncoming(Calls[I], Left);
    Phis[I]->addIncoming(I == 0 ? Calls[0] : Phis[I - 1], Right);
  }
  ASSERT_FALSE(verifyFunction(*F));
  VMCallbacks CB = *getVMCallbacks();
  SubtypeQueries = 0;
  CB.IsSubtype = [](uintptr_t A, uintptr_t Other) {
    ++SubtypeQueries;
    return A == Other || Other == 5;
  };
  registerVMCallbacks(CB);
  EXPECT_EQ(query(Phis[0]), JavaType(9, false));
  EXPECT_LT(SubtypeQueries, 32 * Count);
}

TEST_F(JavaBaseTypeTest, FrozenInvariantGroupResultNeedsDefinedResult) {
  Value *A = seed(0, 9, true);
  F->getArg(0)->addAttr(Attribute::NoUndef);
  for (Intrinsic::ID ID :
       {Intrinsic::launder_invariant_group, Intrinsic::strip_invariant_group}) {
    auto *Fn = Intrinsic::getOrInsertDeclaration(&M, ID, {A->getType()});
    auto *Call = B.CreateCall(Fn, {A});
    Call->addRetAttr(Attribute::NonNull);
    EXPECT_TRUE(query(B.CreateFreeze(Call)).isUnknown());
    Call->addRetAttr(Attribute::NoUndef);
    EXPECT_EQ(query(B.CreateFreeze(Call)), JavaType(9, true));
  }
}

TEST_F(JavaBaseTypeTest, ContextTypePropagatesThroughSelectWrappingPhi) {
  checkPattern(R"IR(
    entry:
      %check = call i1 @jeandle.check_instanceof(ptr inttoptr (i64 9 to ptr),
                                               ptr addrspace(1) %unknown)
      br i1 %check, label %pass, label %fail
    pass:
      br label %merge
    fail:
      ret ptr addrspace(1) null
    merge:
      %p = phi ptr addrspace(1) [ %unknown, %pass ]
      %s = select i1 %pick, ptr addrspace(1) %p, ptr addrspace(1) %a
      ret ptr addrspace(1) %s
  )IR",
               0, false, 9, false);
  checkPattern(R"IR(
    entry:
      %check = call i1 @jeandle.check_instanceof(ptr inttoptr (i64 9 to ptr),
                                               ptr addrspace(1) %unknown)
      br i1 %check, label %pass, label %fail
    pass:
      br label %merge
    fail:
      ret ptr addrspace(1) null
    merge:
      %p = phi ptr addrspace(1) [ %unknown, %pass ]
      %r = call ptr addrspace(1) @identity(ptr addrspace(1) %p)
      %g = getelementptr i8, ptr addrspace(1) %r, i64 0
      %s = select i1 %pick, ptr addrspace(1) %g, ptr addrspace(1) %a
      ret ptr addrspace(1) %s
  )IR",
               0, false, 9, false);
  checkPattern(R"IR(
    entry:
      %check = call i1 @jeandle.check_instanceof(ptr inttoptr (i64 9 to ptr),
                                               ptr addrspace(1) %unknown)
      br i1 %check, label %pass, label %fail
    pass:
      br label %merge
    fail:
      ret ptr addrspace(1) null
    merge:
      %p = phi ptr addrspace(1) [ %unknown, %pass ]
      %f = freeze ptr addrspace(1) %p
      %s = select i1 %pick, ptr addrspace(1) %f, ptr addrspace(1) %a
      ret ptr addrspace(1) %s
  )IR",
               0, false, 0, false);
}

} // namespace
