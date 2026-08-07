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

#include "llvm/Analysis/DomTreeUpdater.h"
#include "llvm/IR/Attributes.h"
#include "llvm/IR/Dominators.h"
#include "llvm/IR/Function.h"
#include "llvm/IR/IRBuilder.h"
#include "llvm/IR/InstrTypes.h"
#include "llvm/IR/Jeandle/Attributes.h"
#include "llvm/IR/Jeandle/Deoptimization.h"
#include "llvm/IR/Jeandle/JavaType.h"

namespace llvm {

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
/// \returns If insert checkcast success, return the fail block for checkcast,
/// otherwise return nullptr.
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

/// Finds or creates the LLVM declaration for a concrete Java method.
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
                                        bool IsAccessor);

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

// If `LI` is a load from an oop_handle_* global, return its id.
inline std::optional<int> getOopHandleLoadId(LoadInst *LI) {
  if (!LI || !jeandle::isJavaOopType(LI->getType()))
    return std::nullopt;
  return jeandle::getOopHandleId(LI->getPointerOperand());
}

} // namespace llvm

#endif // LLVM_TRANSFORMS_JEANDLE_JEANDLEUTILS_H
