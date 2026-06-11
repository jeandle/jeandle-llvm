//===- VMCallback.h - VM Callback Interface -------------------------------===//
//
// Copyright (c) 2026, the Jeandle-LLVM Authors. All Rights Reserved.
//
// Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM
// Exceptions. See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//
//
// Callback interface from LLVM optimization passes to the JVM.
// The JVM registers callbacks during compiler initialization; LLVM passes
// invoke them to query VM-level type hierarchy information.
//
//===----------------------------------------------------------------------===//

#ifndef JEANDLE_VM_CALLBACK_H
#define JEANDLE_VM_CALLBACK_H

#include <cstdint>

namespace llvm::jeandle {

// =============================================================================
// Callback type descriptors (used by logging/replay schema)
// =============================================================================

/// Value type for VM callback parameters and results.
enum class VMCallbackValueType : uint8_t {
  Bool,    // bool
  Uintptr, // uintptr_t
  Int,     // int
  Long,    // int64_t
};

// =============================================================================
// Master callback list — add new callbacks here
// =============================================================================
//
// ALL_JEANDLE_VM_CALLBACKS(def) invokes `def` for each VM callback with:
//   Name     — callback name (struct field, CK_ prefix, stringification)
//   RetType  — C++ return type (bool, uintptr_t)
//   ResType  — VMCallbackValueType enum suffix (Bool, Uintptr, Int)
//   Params   — parenthesized parameter declarations,
//              e.g. (uintptr_t a1, uintptr_t a2)
//   Args     — parenthesized argument names, e.g. (a1, a2)
//   ArgTypes — parenthesized VMCallbackValueType enum values, e.g.
//              (VMCallbackValueType::Uintptr, VMCallbackValueType::Uintptr)
//   NumArgs  — number of arguments
//
// -----------------------------------------------------------------------------
// Map-Based Replay and Purity Assumption
//
// The VMCallback replay mechanism uses a map from (CallbackKind, Args) to
// Result. Replay is order-independent: a callback during replay finds its
// result by key lookup, not by sequential cursor advancement.
//
// All VM callbacks are assumed to be PURE FUNCTIONS: the same arguments
// always produce the same result within a single compilation. If the same
// (Kind, Args) is called with a different Result during recording, a fatal
// error is reported (purity violation).
//
// DIVERGENCE RISK: While the map-based model eliminates ordering
// requirements, callbacks must NOT be invoked in non-deterministic control
// flow where the SET of callbacks invoked differs between record and replay.
// This causes missing-key errors during replay.
//
// The key question is: when is iteration order non-deterministic?
//
//   - SmallDenseSet<uintptr_t>: SAFE. LLVM's DenseMapInfo<uintptr_t> uses
//     a pure deterministic hash (densemap::detail::mix) with no randomization
//     or ASLR dependency. Iteration order is fully determined by the set of
//     elements and their insertion/deletion history, which are the same
//     between record and replay given the same IR and callback results.
//
//   - DenseMap<T*> / SmallDenseSet<T*> where T is a pointer type: UNSAFE.
//     DenseMapInfo<T*> hashes the pointer address, which depends on ASLR
//     and memory layout. Iteration order can differ between the JVM process
//     (recording) and the opt process (replay).
//
//   - Any container with per-run randomization (e.g., LLVM's ReverseIterate
//     mode with LLVM_ENABLE_REVERSE_ITERATION=1): UNSAFE.
//
// Patterns to AVOID:
//   - Early exit (break/return) from iteration over a container with
//     non-deterministic iteration order (e.g., DenseMap<T*>) where the
//     exit condition depends on a callback result. Different iteration
//     orders may cause different callbacks to be invoked before the exit,
//     changing the recorded set.
//
//     BAD:  for (auto &Entry : DenseMap<SomeClass*, ...>) {
//             if (IsSubtype(Entry.key, K)) return true;
//           }
//
// Patterns that are SAFE:
//   - Iterating SmallDenseSet<uintptr_t> with early exits (the current
//     usage in isExcludedBy, addExcludedKlass, etc.). The hash function
//     for uintptr_t is deterministic, so iteration order is reproducible.
//   - Exhaustive iteration over any container (no early exit), where every
//     callback in the set is always invoked regardless of iteration order.
//     The map handles the ordering difference transparently.
//   - Iterating ordered containers (arrays, sorted vectors, instruction
//     lists) where iteration order is deterministic.
//   - Any callback whose arguments are derived from deterministic inputs
//     (instruction order, metadata, constants).
// -----------------------------------------------------------------------------
//
// To add a new callback, add one row below, then implement the JDK-side
// function in jeandleVMCallback.cpp and wire it in
// register_jeandle_vm_callbacks().
//
#define ALL_JEANDLE_VM_CALLBACKS(def)                                            \
  def(IsSubtype, bool, Bool,                                                     \
      (uintptr_t a1, uintptr_t a2), (a1, a2),                                    \
      (VMCallbackValueType::Uintptr, VMCallbackValueType::Uintptr), 2)           \
  def(GetCommonSuperKlass, uintptr_t, Uintptr,                                   \
      (uintptr_t a1, uintptr_t a2), (a1, a2),                                    \
      (VMCallbackValueType::Uintptr, VMCallbackValueType::Uintptr), 2)           \
  def(GetFieldType, uintptr_t, Uintptr,                                          \
      (uintptr_t a1, int a2), (a1, a2),                                          \
      (VMCallbackValueType::Uintptr, VMCallbackValueType::Int), 2)               \
  def(IsInterface, bool, Bool,                                                   \
      (uintptr_t a1), (a1),                                                      \
      (VMCallbackValueType::Uintptr), 1)                                         \
  def(IsObjectKlass, bool, Bool,                                                 \
      (uintptr_t a1), (a1),                                                      \
      (VMCallbackValueType::Uintptr), 1)                                         \
  def(IsEffectivelyFinal, bool, Bool,                                            \
      (uintptr_t a1), (a1),                                                      \
      (VMCallbackValueType::Uintptr), 1)                                         \
  def(IsConstantField, bool, Bool,                                               \
      (int a1, int a2), (a1, a2),                                                \
      (VMCallbackValueType::Int, VMCallbackValueType::Int), 2)                   \
  def(GetFieldBasicTypeByOop, int, Int,                                          \
      (int a1, int a2), (a1, a2),                                                \
      (VMCallbackValueType::Int, VMCallbackValueType::Int), 2)                   \
  def(GetConstantFieldInt, int, Int,                                             \
      (int a1, int a2), (a1, a2),                                                \
      (VMCallbackValueType::Int, VMCallbackValueType::Int), 2)                   \
  def(GetConstantFieldLong, int64_t, Long,                                       \
      (int a1, int a2), (a1, a2),                                                \
      (VMCallbackValueType::Int, VMCallbackValueType::Int), 2)                   \
  def(GetConstantFieldFloatBits, int, Int,                                       \
      (int a1, int a2), (a1, a2),                                                \
      (VMCallbackValueType::Int, VMCallbackValueType::Int), 2)                   \
  def(GetConstantFieldDoubleBits, int64_t, Long,                                 \
      (int a1, int a2), (a1, a2),                                                \
      (VMCallbackValueType::Int, VMCallbackValueType::Int), 2)                   \
  def(GetConstantFieldOop, int, Int,                                             \
      (int a1, int a2), (a1, a2),                                                \
      (VMCallbackValueType::Int, VMCallbackValueType::Int), 2)

// =============================================================================
// VMCallbacks struct — generated from master list
// =============================================================================

/// Generate a typedef + struct field for each callback.
/// Params retains its outer parentheses, which become the function-pointer
/// parameter list: RetType (*) Params => e.g. bool (*)(uintptr_t a1, uintptr_t
/// a2)
#define DEF_VM_CALLBACK_FIELD(Name, RetType, ResType, Params, Args, ArgTypes,  \
                              NumArgs)                                         \
  using Name##Fn = RetType(*) Params;                                          \
  Name##Fn Name = nullptr;

/// All VM callbacks used by Jeandle LLVM passes.
///
/// Fields (generated from ALL_JEANDLE_VM_CALLBACKS above):
///   IsSubtype           — Returns true if SubKlass is a subtype of SuperKlass.
///   GetCommonSuperKlass — Given two klass pointers, return their lowest common
///                         ancestor. Returns 0 if unknown.
///   GetFieldType        — Given a klass pointer and byte offset, return the
///                         field's declared type klass pointer. Returns 0 if
///                         unknown.
///   IsInterface         — Returns true if the klass is an interface.
///   IsObjectKlass       — Returns true if the klass is java.lang.Object.
///   IsEffectivelyFinal  — Returns true if no subclass can exist at runtime.
///   IsConstantField     — Returns true if oop id + byte offset is foldable.
///   GetFieldBasicTypeByOop
///                       — Returns the HotSpot BasicType value for a field.
///   GetConstantFieldInt — Returns widened int value for boolean/byte/char/
///                         short/int fields.
///   GetConstantFieldLong
///                       — Returns long value.
///   GetConstantFieldFloatBits
///                       — Returns raw int bits for float fields.
///   GetConstantFieldDoubleBits
///                       — Returns raw long bits for double fields.
///   GetConstantFieldOop — Returns stable oop id for object/array field value,
///                         or -1 for null.
struct VMCallbacks {
  ALL_JEANDLE_VM_CALLBACKS(DEF_VM_CALLBACK_FIELD)
};

#undef DEF_VM_CALLBACK_FIELD

/// Register VM callbacks. Must be called before running the optimization
/// pipeline (typically once during compiler initialization).
void registerVMCallbacks(const VMCallbacks &CB);

/// Retrieve the registered VM callbacks. Returns nullptr if not registered.
const VMCallbacks *getVMCallbacks();

} // namespace llvm::jeandle

#endif // JEANDLE_VM_CALLBACK_H
