//===- JeandleTransformUtils.cpp - Some common helper functions -----------===//
//
// Copyright (c) 2025, the Jeandle-LLVM Authors. All Rights Reserved.
//
// Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM
// Exceptions. See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#include "llvm/Transforms/Jeandle/JeandleTransformUtils.h"
#include "llvm/Analysis/DomTreeUpdater.h"
#include "llvm/Analysis/Jeandle/PartialEscapeUtils.h"
#include "llvm/Analysis/LazyValueInfo.h"
#include "llvm/IR/GlobalVariable.h"
#include "llvm/IR/Jeandle/Deoptimization.h"
#include "llvm/IR/Jeandle/GCStrategy.h"
#include "llvm/IR/Jeandle/Metadata.h"
#include "llvm/IR/Jeandle/VMCallback.h"
#include "llvm/IR/Module.h"
#include "llvm/Support/MathExtras.h"
#include "llvm/Transforms/Utils/BasicBlockUtils.h"

#include <limits>
#include <string>

namespace llvm {

std::optional<JavaVirtualCallSite> getJavaVirtualCallSite(InvokeInst &CB) {
  if (CB.arg_empty() || !CB.hasDeoptState())
    return std::nullopt;

  Attribute BytecodeAttr = CB.getFnAttr(jeandle::Attribute::Bytecode);
  if (!checkStringAttr(BytecodeAttr))
    return std::nullopt;
  StringRef Bytecode = BytecodeAttr.getValueAsString();
  jeandle::InvokeType InvokeKind = jeandle::getInvokeType(Bytecode);
  if (InvokeKind != jeandle::InvokeVirtual &&
      InvokeKind != jeandle::InvokeInterface)
    return std::nullopt;

  Function *Callee = CB.getCalledFunction();
  Value *Receiver = CB.getArgOperand(0);
  if (!Callee || !Receiver->getType()->isPointerTy())
    return std::nullopt;

  JavaVirtualCallSite CallSite;
  CallSite.Receiver = Receiver;
  CallSite.InvokeKind = InvokeKind;
  if (!getFunctionJavaMethod(*Callee, CallSite.CalleeMethod) ||
      !getUIntPtrFnAttr(CB, jeandle::Attribute::DeclaredHolder,
                        CallSite.DeclaredHolder) ||
      !getUIntFnAttr(CB, jeandle::Attribute::StatepointID,
                     CallSite.StatepointID) ||
      CallSite.StatepointID > std::numeric_limits<uint32_t>::max())
    return std::nullopt;
  return CallSite;
}

int getStaticCallPatchSize(const Module &M) {
  NamedMDNode *NMD = M.getNamedMetadata(jeandle::Metadata::StaticCallPatchSize);
  assert(NMD && NMD->getNumOperands() == 1 && "expected patch size metadata");
  MDNode *PatchNode = NMD->getOperand(0);
  assert(PatchNode && PatchNode->getNumOperands() == 1 &&
         "expected one patch size operand");
  return mdconst::extract<ConstantInt>(PatchNode->getOperand(0))
      ->getSExtValue();
}

bool canGetOrInsertJavaMethodFunction(const Module &M, StringRef Name,
                                      FunctionType *Type, uintptr_t Method) {
  const Function *F = M.getFunction(Name);
  if (!F)
    return true;
  uintptr_t ExistingMethod = 0;
  return F->getFunctionType() == Type &&
         getFunctionJavaMethod(*F, ExistingMethod) && ExistingMethod == Method;
}

Function *getOrInsertJavaMethodFunction(Module &M, StringRef Name,
                                        FunctionType *Type, uintptr_t Method,
                                        bool IsAccessor) {
  if (!canGetOrInsertJavaMethodFunction(M, Name, Type, Method))
    return nullptr;

  Function *F = M.getFunction(Name);
  if (!F) {
    F = Function::Create(Type, GlobalValue::ExternalLinkage, Name, M);
    F->addFnAttr(Attribute::get(M.getContext(), jeandle::Attribute::JavaMethod,
                                std::to_string(Method)));
  }
  F->setCallingConv(CallingConv::Hotspot_JIT);
  F->setGC(jeandle::JeandleGC);
  if (IsAccessor)
    F->addFnAttr(
        Attribute::get(M.getContext(), jeandle::Attribute::JavaAccessorMethod));
  return F;
}

void updateStaticOptVirtualCallAttrs(InvokeInst &CB, int PatchSize,
                                     bool MarkNoInline) {
  CB.addParamAttr(0, Attribute::NoUndef);
  CB.removeFnAttr(jeandle::Attribute::StatepointNumPatchBytes);
  CB.addFnAttr(Attribute::get(CB.getContext(),
                              jeandle::Attribute::StatepointNumPatchBytes,
                              std::to_string(PatchSize)));
  CB.addFnAttr(
      Attribute::get(CB.getContext(), jeandle::Attribute::MonomorphicTarget));
  if (MarkNoInline)
    CB.setIsNoInline();
}

void setStatepointID(CallBase &CB, uint64_t StatepointID) {
  CB.removeFnAttr(jeandle::Attribute::StatepointID);
  CB.addFnAttr(Attribute::get(CB.getContext(), jeandle::Attribute::StatepointID,
                              std::to_string(StatepointID)));
}

[[noreturn]] void reportInvalidStatepointID(const CallBase &CB,
                                            StringRef Component,
                                            StringRef Reason) {
  std::string Message;
  raw_string_ostream OS(Message);
  OS << Component << ": " << Reason;
  if (const Function *Caller = CB.getCaller())
    OS << " in " << Caller->getName();
  OS << ": " << CB;
  OS.flush();
  report_fatal_error(StringRef(Message));
}

namespace {

struct DeoptScopeInfo {
  unsigned BCIPairStart = 0;
  int BCI = -1;
};

[[noreturn]] void reportInvalidDeoptBundle(const CallBase &CB,
                                           const char *Reason) {
  std::string Message;
  raw_string_ostream OS(Message);
  OS << "JeandleTransformUtils: " << Reason;
  if (const Function *Caller = CB.getCaller())
    OS << " in " << Caller->getName();
  OS << ": " << CB;
  OS.flush();
  report_fatal_error(StringRef(Message));
}

DeoptScopeInfo findCurrentDeoptScope(const CallBase &CB) {
  // Built on the shared graceful finder (jeandle::pea::
  // findInnermostDeoptScopeBCIPairStart). The innermost variant is now used
  // only by this file's computeDeoptStackLayout — PEA's analysis side and
  // getDeoptScopeVOInsertPos anchor on the FIRST (root) scope via
  // findFirstDeoptScopeBCIPairStart instead. The transform side keeps the
  // hard failure: every Jeandle frontend path that reaches these transforms
  // upholds the well-formed-bundle invariant, so a malformed bundle here is
  // a genuine bug.
  // TODO(robustness): thread std::optional<DeoptScopeInfo> through
  // getDeoptScopeVOInsertPos + computeDeoptStackLayout and their callers
  // instead; deferred as it is not cheap.
  if (!CB.getOperandBundle(LLVMContext::OB_deopt))
    reportInvalidDeoptBundle(CB, "missing deopt bundle for bci");
  std::optional<unsigned> Start =
      jeandle::pea::findInnermostDeoptScopeBCIPairStart(CB);
  if (!Start)
    reportInvalidDeoptBundle(
        CB, "missing or mismatched adjacent i32 deopt bci pair");
  return {*Start, 0};
}

} // namespace

static Function *getDeoptimizeCallee(Module &M, Type *RetTy) {
  Function *DeoptDecl = Intrinsic::getOrInsertDeclaration(
      &M, Intrinsic::experimental_deoptimize, {RetTy});
  DeoptDecl->setCallingConv(CallingConv::Hotspot_JIT);
  return DeoptDecl;
}

static CallInst *createConstraintInst(Value *Receiver, uintptr_t Constraint,
                                      IRBuilder<> &Builder, Function *CheckFn) {
  LLVMContext &Context = CheckFn->getContext();
  PointerType *KlassTy =
      PointerType::get(Context, jeandle::AddrSpace::CHeapAddrSpace);
  Value *ConstraintValue =
      Builder.CreateIntToPtr(Builder.getInt64(Constraint), KlassTy);

  FunctionCallee Callee(CheckFn);
  CallInst *Checkcast = Builder.CreateCall(Callee, {ConstraintValue, Receiver},
                                           ArrayRef<OperandBundleDef>{});
  Checkcast->setCallingConv(CallingConv::Hotspot_JIT);
  return Checkcast;
}

void buildDeoptimize(IRBuilder<> &Builder, Module &M,
                     jeandle::Deoptimization::DeoptReason Reason,
                     jeandle::Deoptimization::DeoptAction Action,
                     const OperandBundleDef &DeoptBundle) {
  Value *Request = Builder.getInt32(
      jeandle::Deoptimization::makeTrapRequest(Reason, Action));

  Function *Parent = Builder.GetInsertBlock()->getParent();
  Type *RetTy = Parent->getReturnType();
  Function *Callee = getDeoptimizeCallee(M, RetTy);
  CallInst *Call = Builder.CreateCall(Callee, {Request}, {DeoptBundle});
  Call->setCallingConv(CallingConv::Hotspot_JIT);

  if (RetTy->isVoidTy())
    Builder.CreateRetVoid();
  else
    Builder.CreateRet(Call);
}

BasicBlock *insertCheckInstanceOf(Instruction &Inst, Value *Receiver,
                                  uintptr_t Constraint, const StringRef &Prefix,
                                  DomTreeUpdater *DTU) {
  assert(Receiver->getType()->isPointerTy() && "Receiver must be a pointer");
  BasicBlock *BB = Inst.getParent();
  Module *M = Inst.getModule();
  Function *CheckFn = M->getFunction("jeandle.check_instanceof");
  assert(CheckFn && "jeandle.check_instanceof not found");

  LLVMContext &Context = Inst.getContext();

  BasicBlock *CheckcastPass = SplitBlock(BB, &Inst, DTU, nullptr, nullptr,
                                         Prefix + "_check_receiver_pass");
  BasicBlock *CheckcastFail = BasicBlock::Create(
      Context, Prefix + "_check_receiver_fail", BB->getParent(), CheckcastPass);

  BB->getTerminator()->eraseFromParent();
  IRBuilder<> BuilderOrigin(BB);
  CallInst *Checkcast =
      createConstraintInst(Receiver, Constraint, BuilderOrigin, CheckFn);

  BuilderOrigin.CreateCondBr(Checkcast, CheckcastPass, CheckcastFail);
  if (DTU) {
    DTU->applyUpdates({{DominatorTree::Insert, BB, CheckcastFail}});
    DTU->flush();
  }
  return CheckcastFail;
}

BasicBlock *insertNullCheck(Instruction &Inst, Value *Receiver,
                            const StringRef &Prefix, DomTreeUpdater *DTU) {
  LLVMContext &Context = Inst.getContext();
  BasicBlock *BB = Inst.getParent();

  assert(Receiver->getType() ==
             PointerType::get(Context, jeandle::AddrSpace::JavaHeapAddrSpace) &&
         "must be a java object");
  BasicBlock *NullCheckPass =
      SplitBlock(BB, &Inst, DTU, nullptr, nullptr, Prefix + "_null_check_pass");
  BasicBlock *NullCheckFail = BasicBlock::Create(
      Context, Prefix + "_null_check_fail", BB->getParent(), NullCheckPass);

  BB->getTerminator()->eraseFromParent();
  IRBuilder<> BuilderOrigin(BB);
  Value *IfNull = BuilderOrigin.CreateICmp(
      CmpInst::ICMP_EQ, Receiver,
      ConstantPointerNull::get(cast<PointerType>(Receiver->getType())));
  BranchInst *NullCheckBr =
      BuilderOrigin.CreateCondBr(IfNull, NullCheckFail, NullCheckPass);
  // Add make.implicit metadata, and the ImplicitNullChecksPass will transform
  // it into an implicit check.
  MDNode *MakeImplicit = MDNode::get(Context, {});
  NullCheckBr->setMetadata(LLVMContext::MD_make_implicit, MakeImplicit);

  if (DTU) {
    DTU->applyUpdates({{DominatorTree::Insert, BB, NullCheckFail}});
    DTU->flush();
  }

  return NullCheckFail;
}

CallInst *insertJavaTypeAssume(Value *V, jeandle::JavaType T, Instruction *I) {
  Module *M = I->getModule();
  Function *AssumeFn = M->getFunction("jeandle.assume_java_type");
  assert(AssumeFn && "jeandle.assume_java_type must exist in the module");

  IRBuilder<> Builder(I);
  CallInst *Assume =
      Builder.CreateCall(AssumeFn, {V},
                         V->hasName() ? Twine(V->getName()) + ".type_assume"
                                      : Twine("type_assume"));
  Assume->setCallingConv(CallingConv::Hotspot_JIT);

  LLVMContext &Context = I->getContext();
  Assume->addRetAttr(Attribute::get(Context, jeandle::Attribute::JavaKlass,
                                    std::to_string(T.Klass)));
  if (T.Exact)
    Assume->addRetAttr(
        Attribute::get(Context, jeandle::Attribute::JavaKlassExact));

  return Assume;
}

int getCurrentDeoptBCI(const CallBase &CB) {
  // The bytecode index is the first i32 of the current (innermost) deopt
  // scope's adjacent bci pair, located at BCIPairStart.
  DeoptScopeInfo Scope = findCurrentDeoptScope(CB);
  OperandBundleUse Deopt = *CB.getOperandBundle(LLVMContext::OB_deopt);
  const auto *BCI = cast<ConstantInt>(Deopt.Inputs[Scope.BCIPairStart].get());
  return static_cast<int>(BCI->getSExtValue());
}

uintptr_t getCurrentDeoptMethod(const CallBase &CB, uintptr_t RootMethod) {
  DeoptScopeInfo Scope = findCurrentDeoptScope(CB);
  // Root scopes either begin with the duplicated BCI pair (legacy IR) or with
  // an i64 should-reexecute flag followed by that pair.
  if (Scope.BCIPairStart <= 1)
    return RootMethod;

  OperandBundleUse Deopt = *CB.getOperandBundle(LLVMContext::OB_deopt);
  auto DecodeMethod = [&](unsigned EncodingIndex,
                          unsigned MethodIndex) -> uintptr_t {
    auto *Encoding = dyn_cast<ConstantInt>(Deopt.Inputs[EncodingIndex].get());
    auto *Method = dyn_cast<ConstantInt>(Deopt.Inputs[MethodIndex].get());
    if (!Encoding || !Encoding->getType()->isIntegerTy(64) || !Method ||
        !Method->getType()->isIntegerTy(64))
      return 0;
    const uint64_t MethodEncoding =
        jeandle::DeoptValueEncoding(0, jeandle::DeoptValueEncoding::MethodType,
                                    jeandle::T_METADATA)
            .encode();
    if (Encoding->getZExtValue() != MethodEncoding)
      return 0;
    return static_cast<uintptr_t>(Method->getZExtValue());
  };

  // Current inlinee layout: method marker, method, should-reexecute, bci, bci.
  if (Scope.BCIPairStart >= 3) {
    if (uintptr_t Method =
            DecodeMethod(Scope.BCIPairStart - 3, Scope.BCIPairStart - 2))
      return Method;
  }

  reportInvalidDeoptBundle(CB, "missing inlinee method before bci");
}

static std::pair<unsigned, unsigned> computeDeoptStackLayout(CallBase &CB) {
  OperandBundleUse Deopt = *CB.getOperandBundle(LLVMContext::OB_deopt);
  unsigned Slots = 0;
  unsigned InsertPos = findCurrentDeoptScope(CB).BCIPairStart + 2;
  // Each deopt scope starts with a duplicated BCI pair. Inlined scopes are
  // appended after their callers, so the current Java call site is the final
  // scope. Canonical per-scope order is:
  // [method], should-reexecute, bci, bci, locals, stack, monitors, orig_pc.
  for (; InsertPos < Deopt.Inputs.size();) {
    auto *Encoding = dyn_cast<ConstantInt>(Deopt.Inputs[InsertPos].get());
    assert(Encoding != nullptr && "expected deopt value encoding");

    jeandle::DeoptValueEncoding DeoptInfo =
        jeandle::DeoptValueEncoding::decode(Encoding->getZExtValue());

    if (DeoptInfo.valueType() == jeandle::DeoptValueEncoding::StackType) {
      assert(Slots == DeoptInfo.index() && "Stack index should be in order.");
      Slots += jeandle::isDoubleWordType(DeoptInfo.basicType()) ? 2 : 1;
      InsertPos += 2;
    } else if (DeoptInfo.valueType() ==
               jeandle::DeoptValueEncoding::LocalType) {
      InsertPos += 2;
    } else {
      break;
    }
  }

  return {InsertPos, Slots};
}

OperandBundleDef createPreCallDeoptBundle(InvokeInst &CB) {
  assert(CB.hasOperandBundles() && "must have deopt bundle for java invoke");
  OperandBundleUse Deopt = *CB.getOperandBundle(LLVMContext::OB_deopt);

  SmallVector<Value *, 16> Args;
  Args.reserve(Deopt.Inputs.size() + CB.arg_size() * 2);

  LLVMContext &Context = CB.getContext();
  auto [InsertPos, StackIndex] = computeDeoptStackLayout(CB);

  for (unsigned I = 0; I < InsertPos; ++I)
    Args.push_back(Deopt.Inputs[I].get());

  for (Value *Arg : CB.args()) {
    jeandle::HotspotBasicType TypeKind =
        jeandle::LLVM2JavaComputational(Arg->getType());
    assert(TypeKind != jeandle::T_ILLEGAL);

    uint64_t Encoding =
        jeandle::DeoptValueEncoding(
            StackIndex, jeandle::DeoptValueEncoding::StackType, TypeKind)
            .encode();

    Args.push_back(ConstantInt::get(Type::getInt64Ty(Context), Encoding));
    Args.push_back(Arg);
    StackIndex += jeandle::isDoubleWordType(TypeKind) ? 2 : 1;
  }

  for (unsigned I = InsertPos; I < Deopt.Inputs.size(); ++I)
    Args.push_back(Deopt.Inputs[I].get());

  return OperandBundleDef("deopt", Args);
}

LoadInst *createConstOopLoad(Module &M, IRBuilder<> &Builder, int OopId) {
  LLVMContext &Ctx = M.getContext();
  Type *OopTy = PointerType::get(Ctx, jeandle::AddrSpace::JavaHeapAddrSpace);
  const auto *CB = jeandle::getVMCallbacks();
  assert(CB && CB->GetOopHandleName && "GetOopHandleName callback required");
  std::string Name = CB->GetOopHandleName(OopId);
  GlobalVariable *GV = cast<GlobalVariable>(M.getOrInsertGlobal(Name, OopTy));
  GV->setDSOLocal(true);
  LoadInst *LI = Builder.CreateLoad(OopTy, GV, "folded.oop");
  LI->setMetadata(LLVMContext::MD_nonnull, MDNode::get(Ctx, {}));
  return LI;
}

void appendVirtualObjectDescriptor(SmallVectorImpl<Value *> &Args,
                                   IRBuilder<> &B, uint64_t Klass,
                                   unsigned VObjID, bool IsArray,
                                   ArrayRef<VODescriptorField> Fields) {
  // Single emit chokepoint for PEA deopt VO descriptors. See the contract on
  // DeoptValueEncoding::ScalarValueType (include/llvm/IR/Jeandle/
  // Deoptimization.h) and appendVirtualObjectDescriptor in the header. The
  // parser consumes (3 + 2*field_count) wire locations for one descriptor.
  // Each field or array element is one typed wire pair. For T_LONG/T_DOUBLE,
  // HotSpot expands that pair to two ScopeValue slots.
  LLVMContext &Ctx = B.getContext();

  // [header] DeoptValueEncoding(VObjID, ScalarValueType, T_ARRAY|T_OBJECT).
  // The header basicType tells the HotSpot parser whether to rebuild an array
  // (T_ARRAY, uniform elements indexed by offset, field_count == length) or an
  // instance (T_OBJECT, fields matched to an InstanceKlass layout walk).
  jeandle::HotspotBasicType HeaderBT =
      IsArray ? jeandle::T_ARRAY : jeandle::T_OBJECT;
  uint64_t Header =
      jeandle::DeoptValueEncoding(
          VObjID, jeandle::DeoptValueEncoding::ScalarValueType, HeaderBT)
          .encode();
  Args.push_back(ConstantInt::get(Type::getInt64Ty(Ctx), Header));

  // [klass] raw InstanceKlass / ArrayKlass identity
  Args.push_back(B.getInt64(Klass));

  // [field_count]
  Args.push_back(B.getInt32(Fields.size()));

  // [field i] (DeoptValueEncoding(offset, LocalType/VORefLocalType, bt), value)
  // The offset rides in the encoding's Index field so the HotSpot parser can
  // match each emitted field to an InstanceKlass field (instance) or compute
  // the element index (array) and pad the untouched fields with defaults
  // (reassign_fields_by_klass consumes ALL non-static fields). Field order in
  // the bundle is irrelevant — the parser keys by offset. A scalar field
  // carries enc(offset, LocalType, BasicTy) + the concrete Value; a VORef
  // field carries enc(offset, VORefLocalType, T_OBJECT) + the referenced VO's
  // vo-id as an i32 constant (transitive VO references / cycles). For an
  // array the caller has already expanded ALL elements (touched + default) into
  // Fields, so field_count == ArrayLength.
  for (const VODescriptorField &F : Fields) {
    assert(isInt<32>(F.Offset) &&
           "PEA deopt field offset must fit DeoptValueEncoding::Index");
    if (F.IsVORef) {
      uint64_t FieldEnc =
          jeandle::DeoptValueEncoding(
              static_cast<int>(F.Offset),
              jeandle::DeoptValueEncoding::VORefLocalType, jeandle::T_OBJECT)
              .encode();
      Args.push_back(ConstantInt::get(Type::getInt64Ty(Ctx), FieldEnc));
      Args.push_back(B.getInt32(F.VORefID));
    } else {
      uint64_t FieldEnc = jeandle::DeoptValueEncoding(
                              static_cast<int>(F.Offset),
                              jeandle::DeoptValueEncoding::LocalType, F.BasicTy)
                              .encode();
      Args.push_back(ConstantInt::get(Type::getInt64Ty(Ctx), FieldEnc));
      Args.push_back(F.V);
    }
  }
}

unsigned getDeoptScopeVOInsertPos(const CallBase &CB) {
  // The VO section is the deopt-point-level object pool: it sits in the ROOT
  // (outermost) scope, right AFTER the FIRST duplicated-BCI marker and BEFORE
  // the root scope's locals, so every descriptor precedes any VORef slot in
  // any scope (the HotSpot parser walks scopes outermost-first and resolves
  // VORefs through a record-level vo_map). Mirrors C2's dump_object_pool
  // before create_scope_values. findFirstDeoptScopeBCIPairStart returns the
  // index of the first BCI of the FIRST adjacent-equal i32 pair; the insert
  // position is immediately past the pair (BCIPairStart + 2). The transform
  // keeps the hard failure on malformed bundles (frontend invariant), unlike
  // the analysis side's graceful bail.
  if (!CB.getOperandBundle(LLVMContext::OB_deopt))
    reportInvalidDeoptBundle(CB, "missing deopt bundle for VO section");
  std::optional<unsigned> Start =
      jeandle::pea::findFirstDeoptScopeBCIPairStart(CB);
  if (!Start)
    reportInvalidDeoptBundle(
        CB, "missing or mismatched adjacent i32 deopt bci pair");
  return *Start + 2;
}

/// LazyValueInfo-backed null-edge oracle. This fork's getPredicateOnEdge
/// returns a Constant*: the constant result of the comparison, or nullptr when
/// unknown. Unknown answers false (the edge is kept) — only positive proof may
/// skip an edge. V is stripped of pointer casts, aliases and freeze wrappers
/// (the same canonicalization the engine uses) so a null test on the
/// underlying oop is still recognized when the query value carries a wrapper
/// (freeze(x) equals x unless x is poison, and branching on poison is
/// undefined, so null proofs transfer).
bool LVINullEdgeOracle::operator()(Value *V, BasicBlock *FromBB,
                                   BasicBlock *ToBB) const {
  while (true) {
    V = V->stripPointerCastsAndAliases();
    if (auto *FI = dyn_cast<FreezeInst>(V)) {
      V = FI->getOperand(0);
      continue;
    }
    break;
  }
  auto *PT = dyn_cast<PointerType>(V->getType());
  if (!PT)
    return false;
  Constant *C = LVI.getPredicateOnEdge(
      ICmpInst::ICMP_EQ, V, ConstantPointerNull::get(PT), FromBB, ToBB);
  return C && C->isOneValue();
}

} // namespace llvm
