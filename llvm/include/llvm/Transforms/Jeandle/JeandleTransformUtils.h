//===- JeandleTransformUtils.h - Some common helper functions -------------===//
//
// Copyright (c) 2026, the Jeandle-LLVM Authors. All Rights Reserved.
//
// Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM
// Exceptions. See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#ifndef LLVM_TRANSFORMS_JEANDLE_JEANDLEUTILS_H
#define LLVM_TRANSFORMS_JEANDLE_JEANDLEUTILS_H

#include "llvm/ADT/STLFunctionalExtras.h"
#include "llvm/ADT/SmallVector.h"
#include "llvm/Analysis/DomTreeUpdater.h"
#include "llvm/IR/Attributes.h"
#include "llvm/IR/Dominators.h"
#include "llvm/IR/Function.h"
#include "llvm/IR/IRBuilder.h"
#include "llvm/IR/InstrTypes.h"
#include "llvm/IR/Jeandle/Attributes.h"
#include "llvm/IR/Jeandle/Deoptimization.h"
#include "llvm/IR/Jeandle/InvokeType.h"
#include "llvm/IR/Jeandle/JavaType.h"
#include "llvm/IR/Jeandle/JeandleUtils.h"
#include "llvm/IR/Module.h"

#include <cstdint>
#include <optional>

namespace llvm {

/// Append a PEA virtual-object (VO) descriptor for a never-escaping instance
/// object into \p Args, the operand list of a "deopt" operand bundle. This is
/// the single emit chokepoint for Jeandle PEA deoptimization support: a VO
/// that is still virtual at a safepoint must be described by a descriptor so
/// HotSpot can reallocate it at deopt.
///
/// The descriptor is the multi-location sequence documented on
/// DeoptValueEncoding::ScalarValueType, emitted in this order:
///   [header]   DeoptValueEncoding(VObjID, ScalarValueType, T_OBJECT|T_ARRAY)
///              .encode()  — T_ARRAY when \p IsArray, else T_OBJECT.
///   [klass]    i64 constant = raw InstanceKlass / ArrayKlass identity
///   [count]    i32 constant = number of (encoding,value) field pairs
///   [field 0]  (DeoptValueEncoding(0, LocalType, basic_type).encode(), value)
///   ...
///   [field N-1]
/// The parser consumes (3 + 2*field_count) locations for one descriptor.
///
/// One emitted VO field: its byte offset (carried in the encoding's Index
/// field so the HotSpot parser can match it to an InstanceKlass field
/// (instance) or compute the element index (array) and pad untouched fields
/// with defaults — HotSpot's reassign_fields_by_klass consumes ALL non-static
/// fields, so the descriptor must be alignable to the full layout), and either
/// a scalar value or a VORef to another in-scope VO.
struct VODescriptorField {
  int64_t Offset;
  jeandle::HotspotBasicType BasicTy;
  // When false: a scalar field; \p V is the concrete value and the field is
  // emitted as (enc(offset, LocalType, BasicTy), V).
  // When true: a VORef field; \p VORefID is the referenced VO's vo-id and the
  // field is emitted as (enc(offset, VORefLocalType, T_OBJECT), i32 VORefID).
  // \p V is unused in this case. See DeoptValueEncoding::ScalarValueType for
  // the wire contract (transitive VO references / cycles).
  bool IsVORef = false;
  Value *V = nullptr;
  unsigned VORefID = 0;
};

/// \p Fields may be in any order; each carries its byte offset. The caller is
/// responsible for computing each scalar field's HotspotBasicType from its
/// declared LLVM type. A VORef field (IsVORef) is emitted with T_OBJECT and the
/// vo-id; BasicTy is ignored for VORef fields. Each long/double field or array
/// element is emitted as one typed wire pair
/// (enc(offset, LocalType, T_LONG/T_DOUBLE), i64/f64 value); the HotSpot parser
/// expands it to the two ScopeValue slots reassign_fields_by_klass consumes.
/// For an array
/// (\p IsArray) the caller MUST expand every element 0..ArrayLength-1 into
/// \p Fields (touched + default) so field_count == ArrayLength; the header
/// basicType is then T_ARRAY. Locks/monitors are out of scope for this
/// helper's callers.
void appendVirtualObjectDescriptor(SmallVectorImpl<Value *> &Args,
                                   IRBuilder<> &B, uint64_t Klass,
                                   unsigned VObjID, bool IsArray,
                                   ArrayRef<VODescriptorField> Fields);

/// Returns the operand index immediately AFTER the duplicated-BCI pair of the
/// FIRST (root/outermost) "deopt" scope on \p CB. The VO descriptor section
/// is placed at this position — AFTER the root scope's duplicated-BCI marker
/// and BEFORE the root locals — and serves as the deopt-point-level object
/// pool: every VO is described before any VORef slot in ANY scope references
/// it (mirrors C2's dump_object_pool before create_scope_values). \p CB must
/// carry a well-formed "deopt" bundle (the same precondition
/// createPreCallDeoptBundle relies on).
unsigned getDeoptScopeVOInsertPos(const CallBase &CB);

/// Canonical LLVM-side view of a well-formed Java virtual invoke.
struct JavaVirtualCallSite {
  Value *Receiver = nullptr;
  uintptr_t CalleeMethod = 0;
  uintptr_t DeclaredHolder = 0;
  uint64_t StatepointID = 0;
  jeandle::InvokeType InvokeKind = jeandle::ILLEGAL;
};

/// Recognizes a Java invokevirtual or invokeinterface instruction and decodes
/// the attributes shared by devirtualization passes.
std::optional<JavaVirtualCallSite> getJavaVirtualCallSite(InvokeInst &CB);

/// Reads the HotSpot patch size used by optimized virtual calls.
int getStaticCallPatchSize(const Module &M);

/// Rewrites a virtual invoke's call-site attributes for an optimized virtual
/// call. \p MarkNoInline prevents the guarded direct call from being considered
/// by the inliner without removing its monomorphic-target marker.
void updateStaticOptVirtualCallAttrs(InvokeInst &CB, int PatchSize,
                                     bool MarkNoInline = false);

/// Replaces the statepoint id carried by a call site.
void setStatepointID(CallBase &CB, uint64_t StatepointID);

/// Reports a malformed statepoint id with call-site context.
[[noreturn]] void reportInvalidStatepointID(const CallBase &CB,
                                            StringRef Component,
                                            StringRef Reason);

/// Emits an llvm.experimental.deoptimize and terminates the current block.
///
/// \param Builder IR builder positioned where the deopt should be inserted.
/// \param M Module used to look up or create the deopt declarations.
/// \param Reason Deoptimization reason.
/// \param Action Deoptimization action.
/// \param DeoptBundle Deoptimization operand bundle attached to the deopt call.
void buildDeoptimize(IRBuilder<> &Builder, Module &M,
                     jeandle::Deoptimization::DeoptReason Reason,
                     jeandle::Deoptimization::DeoptAction Action,
                     const OperandBundleDef &DeoptBundle);

/// Inserts a `jeandle.check_instanceof` guard before an instruction.
///
/// The original block is split at \p Inst. The pass block continues with
///  \p Inst, while the fail block is returned.
///
/// \param Inst Instruction before which the guard is inserted.
/// \param Receiver Object pointer checked by `jeandle.check_instanceof`.
/// \param Constraint VM constraint value, encoded as a Klass pointer-sized
/// integer.
/// \param Prefix Prefix used to name the generated basic blocks.
/// \param DTU Optional dominator tree updater kept in sync with the new CFG,
/// could be null.
/// \returns The fail block for the inserted check.
BasicBlock *insertCheckInstanceOf(Instruction &Inst, Value *Receiver,
                                  uintptr_t Constraint, const StringRef &Prefix,
                                  DomTreeUpdater *DTU = nullptr);

/// Inserts a null check guard before an instruction.
///
/// The original block is split at \p Inst. The pass block continues with
///  \p Inst, while the fail block is returned.
///
/// \param Inst Instruction before which the guard is inserted.
/// \param Receiver Object pointer that will do null check.
/// \param Prefix Prefix used to name the generated basic blocks.
/// \param DTU Optional dominator tree updater kept in sync with the new CFG,
/// could be null.
/// \returns If insert checknull success, return the fail block for checknull,
/// otherwise return nullptr.
BasicBlock *insertNullCheck(Instruction &Inst, Value *Receiver,
                            const StringRef &Prefix,
                            DomTreeUpdater *DTU = nullptr);

/// Inserts a `jeandle.assume_java_type` identity marker before an instruction.
///
/// The returned value is the same oop as \p V, but carries \p T as JavaType
/// information on the call result. This is useful when a single oop value
/// should be interpreted with a narrower Java type at a specific use site.
///
/// \param V Java oop value to reinterpret.
/// \param T Java type attached to the marker result.
/// \param I Instruction before which the marker is inserted.
/// \returns The marker call result.
CallInst *insertJavaTypeAssume(Value *V, jeandle::JavaType T, Instruction *I);

/// Checks whether \p attr is a valid string attribute.
///
/// \returns True when \p attr exists and stores a string value.
inline bool checkStringAttr(const llvm::Attribute &Attr) {
  return Attr.isValid() && Attr.isStringAttribute();
}

/// Parses a non-zero decimal pointer-sized integer.
///
/// \param S Decimal string to parse.
/// \param Out Receives the parsed value on success.
/// \returns True if \p S contains a valid non-zero integer representable by the
/// intermediate parser type.
inline bool parseUIntPtr(StringRef S, uintptr_t &Out) {
  uint64_t V = 0;
  if (S.getAsInteger(10, V) || V == 0)
    return false;
  Out = static_cast<uintptr_t>(V);
  return true;
}

/// Parses a non-zero decimal 64-bit integer.
///
/// \param S Decimal string to parse.
/// \param Out Receives the parsed value on success.
/// \returns True if \p S contains a valid non-zero integer representable by the
/// intermediate parser type.
inline bool parseUInt(StringRef S, uint64_t &Out) {
  uint64_t V = 0;
  if (S.getAsInteger(10, V))
    return false;
  Out = static_cast<uintptr_t>(V);
  return true;
}

/// Reads the Java method pointer encoded on a function.
///
/// \param F Function expected to carry `jeandle::Attribute::JavaMethod`.
/// \param Method Receives the parsed non-zero method pointer on success.
/// \returns True if the attribute exists, is a string attribute, and contains a
/// valid non-zero decimal pointer value.
inline bool getFunctionJavaMethod(const Function &F, uintptr_t &Method) {
  Attribute A = F.getFnAttribute(jeandle::Attribute::JavaMethod);
  if (!checkStringAttr(A))
    return false;
  return parseUIntPtr(A.getValueAsString(), Method);
}

/// Finds or creates the LLVM declaration for a concrete Java method and
/// applies the Jeandle calling convention and GC strategy.
///
/// Java symbols produced by the VM include ciMethod identity so classes with
/// the same binary name from different class loaders remain distinct.  Keep
/// the JavaMethod attribute check as the authoritative validation when a
/// declaration already exists (including standalone/replayed IR).
///
/// \returns A compatible function whose JavaMethod attribute equals \p Method,
/// or nullptr when \p Name is already owned by another Java method/signature.
Function *getOrInsertJavaMethodFunction(Module &M, StringRef Name,
                                        FunctionType *Type, uintptr_t Method,
                                        bool IsAccessor = false);

/// Checks whether getOrInsertJavaMethodFunction can use p Name without
/// mutating the module. This lets multi-target transforms validate every name
/// before creating any declaration.
bool canGetOrInsertJavaMethodFunction(const Module &M, StringRef Name,
                                      FunctionType *Type, uintptr_t Method);

/// Reads a named function attribute from a call and parses it as uintptr_t.
///
/// \param CB Call or invoke instruction carrying the function attribute.
/// \param Name Name of the attribute to read.
/// \param Out Receives the parsed non-zero pointer-sized integer on success.
/// \returns True if the named attribute exists, is a string attribute, and
/// contains a valid non-zero decimal pointer value.
inline bool getUIntPtrFnAttr(const CallBase &CB, StringRef Name,
                             uintptr_t &Out) {
  Attribute A = CB.getFnAttr(Name);
  if (!checkStringAttr(A))
    return false;
  return parseUIntPtr(A.getValueAsString(), Out);
}

inline bool getUIntFnAttr(const CallBase &CB, StringRef Name, uint64_t &Out) {
  Attribute A = CB.getFnAttr(Name);
  if (!checkStringAttr(A))
    return false;
  return parseUInt(A.getValueAsString(), Out);
}

/// Reads the current Java call-site BCI from a deoptimization operand bundle.
///
/// Jeandle deopt bundles are encoded scope by scope. Each scope starts with two
/// adjacent i32 BCI operands; inlined callee scopes are appended after caller
/// scopes and are preceded by a MethodType marker. The current call-site BCI is
/// therefore the last adjacent i32 BCI pair in the bundle.
int getCurrentDeoptBCI(const CallBase &CB);

/// Reads the current Java method from a deoptimization operand bundle.
/// Root scopes omit the MethodType marker and use \p RootMethod instead.
uintptr_t getCurrentDeoptMethod(const CallBase &CB, uintptr_t RootMethod);

/// Compute the pre called deoptimization operand bundle for a Java invoke.
///
/// \param CB Java invoke. With deoptimization operand bundle present.
/// The deoptimization operand bundle describes jvm state for the caller
//  when entering the invoke callee.
/// \returns Pre called deoptimization operand bundle.
OperandBundleDef createPreCallDeoptBundle(InvokeInst &CB);

/// Build a GC-safe load of a constant JavaHeap oop from its oop-handle global
/// `@oop_handle_<klass>_<id>`.
///
/// The global is addrspace(0) storage holding an addrspace(1) pointer; the
/// loaded value is a managed pointer that downstream RewriteStatepointsForGC
/// relocates across safepoints. The JVM resolves the `oop_handle_*` name via
/// oop relocation (jeandleCompiledCode / jeandleReloc). Used by
/// ConstantFieldFolding (constant object/array fields) and PEA's foldGetClass
/// (the `java.lang.Class` mirror of a virtual object's exact klass).
///
/// \param M Module used to look up or create the oop-handle global.
/// \param Builder IR builder positioned where the load should be inserted.
/// \param OopId The constant oop's id (from the VM callback contract).
/// \returns The newly inserted load of the oop-handle global.
LoadInst *createConstOopLoad(Module &M, IRBuilder<> &Builder, int OopId);
// If `LI` is a load from an oop_handle_* global, return its id.
inline std::optional<int> getOopHandleLoadId(LoadInst *LI) {
  if (!LI || !jeandle::isJavaOopType(LI->getType()))
    return std::nullopt;
  return jeandle::getOopHandleId(LI->getPointerOperand());
}

class LazyValueInfo;

/// A jeandle::IsNullEdgeOracle backed by LazyValueInfo: answers "is V provably
/// null on edge FromBB -> ToBB?" via LVI's edge-predicate query. The
/// referenced LVI must stay valid for the queried CFG state — only passes that
/// do not mutate the CFG may hold and use this (LazyValueInfo caches per-block
/// state; splitting or erasing blocks behind its back is unsafe).
struct LVINullEdgeOracle {
  LazyValueInfo &LVI;
  bool operator()(Value *V, BasicBlock *FromBB, BasicBlock *ToBB) const;
};

} // namespace llvm

#endif // LLVM_TRANSFORMS_JEANDLE_JEANDLEUTILS_H
