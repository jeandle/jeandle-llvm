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
#include <string>
#include <tuple>
#include <vector>

namespace llvm::jeandle {

// =============================================================================
// Callback type descriptors (used by logging/replay schema)
// =============================================================================

/// Value type for VM callback parameters and results.
enum class VMCallbackValueType : uint8_t {
  Bool,    // bool
  Int,     // int
  Long,    // int64_t
  Uintptr, // uintptr_t
  String,  // std::string
  Array,   // std::vector<T>, dynamically sized homogeneous values
  Tuple,   // std::tuple<...>, recursively composed from callback value types
};

/// Foldability and raw value are one VM observation and must be recorded as
/// one replayable callback result. A negative BasicType means not foldable and
/// leaves RawValue unspecified (recorded as zero).
using ConstantFieldResult = std::tuple<int, int64_t>;

/// Constraint or holder, target method, packed deoptimization or target info,
/// and target method name returned by CHA devirtualization.
using CHAOptResult = std::tuple<uintptr_t, uintptr_t, uintptr_t, std::string>;

/// A profiled receiver, its resolved method, execution count, and method name.
using ProfileDevirtualizationTargetResult =
    std::tuple<uintptr_t, uintptr_t, int64_t, std::string>;

/// First target, total count, packed deoptimization information, miss policy,
/// and optional second target returned by profile-guided devirtualization.
using ProfileDevirtualizationResult =
    std::tuple<ProfileDevirtualizationTargetResult, int64_t, uintptr_t, bool,
               ProfileDevirtualizationTargetResult>;

/// GetMirrorKlass result used when the oop is not a constant Class mirror or
/// its represented type is unavailable. Zero remains available to encode the
/// known-null Klass field of a primitive Class mirror.
inline constexpr uintptr_t MirrorKlassUnavailable = ~uintptr_t{0};

/// Result reported for an inline attempt after LLVM starts processing it.
/// Keep the numeric values stable because the JVM records them.
enum class JeandleInlineReason : int {
  InlineSuccess = 0,
  RootCalleeUnsupported,
  GetInlineCalleeIRFailed,
  MissingInlineCalleeDefinition,
  NotInlineViable,
  LLVMInlineFailed,
};

// =============================================================================
// Master callback list — add new callbacks here
// =============================================================================
//
// ALL_JEANDLE_VM_CALLBACKS(def) invokes `def` for each VM callback with:
//   Name     — callback name (struct field, CK_ prefix, stringification)
//   RetType  — C++ return type (bool, uintptr_t)
//   ResType  — VMCallbackValueType enum suffix (Bool, Int, Long, Uintptr,
//              String, Array, Tuple)
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
// clang-format off
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
  def(IsUnverifiedInterface, bool, Bool,                                         \
      (uintptr_t a1), (a1),                                                      \
      (VMCallbackValueType::Uintptr), 1)                                         \
  def(IsEffectivelyFinal, bool, Bool,                                            \
      (uintptr_t a1), (a1),                                                      \
      (VMCallbackValueType::Uintptr), 1)                                         \
  def(RequiresStrictLockOrder, int, Int,                                         \
      (), (),                                                                    \
      (), 0)                                                                     \
  def(ElementBasicTypeOfArrayKlass, int, Int,                                    \
      (uintptr_t a1), (a1),                                                      \
      (VMCallbackValueType::Uintptr), 1)                                         \
  def(ArrayElementKlass, uintptr_t, Uintptr,                                     \
      (uintptr_t a1), (a1),                                                      \
      (VMCallbackValueType::Uintptr), 1)                                         \
  def(IsValueBased, bool, Bool,                                                  \
      (uintptr_t a1), (a1),                                                      \
      (VMCallbackValueType::Uintptr), 1)                                         \
  def(IsBoxed, int, Int,                                                         \
      (uintptr_t a1), (a1),                                                      \
      (VMCallbackValueType::Uintptr), 1)                                         \
  def(HasFinalizer, bool, Bool,                                                  \
      (uintptr_t a1), (a1),                                                      \
      (VMCallbackValueType::Uintptr), 1)                                         \
  def(CanVirtualize, bool, Bool,                                                 \
      (uintptr_t a1), (a1),                                                      \
      (VMCallbackValueType::Uintptr), 1)                                         \
  def(GetConstantField, ConstantFieldResult, Tuple,                              \
      (int a1, int a2), (a1, a2),                                                \
      (VMCallbackValueType::Int, VMCallbackValueType::Int), 2)                   \
  def(GetOopHandleName, std::string, String,                                     \
      (int a1), (a1),                                                            \
      (VMCallbackValueType::Int), 1)                                             \
  def(GetOopKlass, uintptr_t, Uintptr,                                           \
      (int a1), (a1),                                                            \
      (VMCallbackValueType::Int), 1)                                             \
  def(GetKlassConstant, uintptr_t, Uintptr,                                      \
      (uintptr_t a1), (a1),                                                      \
      (VMCallbackValueType::Uintptr), 1)                                         \
  def(GetJavaMirror, int, Int,                                                   \
      (uintptr_t a1), (a1),                                                      \
      (VMCallbackValueType::Uintptr), 1)                                         \
  def(GetMirrorKlass, uintptr_t, Uintptr,                                        \
      (int a1), (a1),                                                            \
      (VMCallbackValueType::Int), 1)                                             \
  def(GetKlassLayoutHelper, int, Int,                                            \
      (uintptr_t a1), (a1),                                                      \
      (VMCallbackValueType::Uintptr), 1)                                         \
  def(IsKlassInitialized, bool, Bool,                                            \
      (uintptr_t a1), (a1),                                                      \
      (VMCallbackValueType::Uintptr), 1)                                         \
  def(IsOkToInline, bool, Bool,                                                  \
      (int a1, int a2, uintptr_t a3), (a1, a2, a3),                              \
      (VMCallbackValueType::Int, VMCallbackValueType::Int,                       \
       VMCallbackValueType::Uintptr), 3)                                         \
  def(GetInlineCalleeIR, bool, Bool,                                             \
      (uintptr_t a1), (a1),                                                      \
      (VMCallbackValueType::Uintptr), 1)                                         \
  def(GetNewStatepointID, int64_t, Long,                                         \
      (int64_t a1), (a1),                                                        \
      (VMCallbackValueType::Long), 1)                                            \
  def(RecordInlineResult, bool, Bool,                                            \
      (int a1, int a2, uintptr_t a3, int a4), (a1, a2, a3, a4),                  \
      (VMCallbackValueType::Int, VMCallbackValueType::Int,                       \
       VMCallbackValueType::Uintptr, VMCallbackValueType::Int), 4)               \
  def(RecordInliningComplete, bool, Bool,                                        \
      (), (), (), 0)                                                             \
  def(GetCHAOptInfo, CHAOptResult, Tuple,                                        \
      (uintptr_t a1, uintptr_t a2, uintptr_t a3, uintptr_t a4,                   \
       bool a5, int a6, int a7), (a1, a2, a3, a4, a5, a6, a7),                   \
      (VMCallbackValueType::Uintptr, VMCallbackValueType::Uintptr,               \
       VMCallbackValueType::Uintptr, VMCallbackValueType::Uintptr,               \
       VMCallbackValueType::Bool, VMCallbackValueType::Int,                      \
       VMCallbackValueType::Int), 7)                                             \
  def(UpdateCallSite, bool, Bool,                                                \
      (int64_t a1, int a2, bool a3, uintptr_t a4), (a1, a2, a3, a4),             \
      (VMCallbackValueType::Long, VMCallbackValueType::Int,                      \
       VMCallbackValueType::Bool, VMCallbackValueType::Uintptr), 4)              \
  def(GetSignatureAccessingKlass, uintptr_t, Uintptr,                            \
      (uintptr_t a1), (a1),                                                      \
      (VMCallbackValueType::Uintptr), 1)                                         \
  def(GetSignatureArgType, int64_t, Long,                                        \
      (uintptr_t a1, int a2), (a1, a2),                                          \
      (VMCallbackValueType::Uintptr, VMCallbackValueType::Int), 2)               \
  def(GetSignatureArgTypeKlass, uintptr_t, Uintptr,                              \
      (uintptr_t a1, int a2), (a1, a2),                                          \
      (VMCallbackValueType::Uintptr, VMCallbackValueType::Int), 2)               \
  def(GetProfileDevirtualizationInfo, ProfileDevirtualizationResult, Tuple,      \
      (uintptr_t a1, uintptr_t a2, uintptr_t a3, int a4, int a5),                \
      (a1, a2, a3, a4, a5),                                                     \
      (VMCallbackValueType::Uintptr, VMCallbackValueType::Uintptr,               \
       VMCallbackValueType::Uintptr, VMCallbackValueType::Int,                   \
       VMCallbackValueType::Int), 5)                                             \
  def(UpdateToStaticOptVirtualCall, bool, Bool,                                  \
      (int64_t a1), (a1),                                                        \
      (VMCallbackValueType::Long), 1)                                            \
  def(GetSecondarySupers, std::vector<uintptr_t>, Array,                         \
      (uintptr_t a1), (a1),                                                      \
      (VMCallbackValueType::Uintptr), 1)
// clang-format on

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
///   GetFieldType        — Given an instance klass pointer and byte offset,
///                         return the declared type klass pointer of the field
///                         stored at that offset, searching the class's own
///                         fields and inherited fields up the superclass chain.
///                         Returns 0 if no field exists at that offset in the
///                         hierarchy (including for non-instance klasses such
///                         as arrays) or if the field's type is primitive.
///   IsInterface         — Returns true if the klass is an interface.
///   IsObjectKlass       — Returns true if the klass is java.lang.Object.
///   IsUnverifiedInterface
///                       — Returns true if the klass is an interface type whose
///                         type the bytecode verifier does not enforce. Covers
///                         interface instance klasses and objArray klasses
///                         whose bottom element is such an interface. Type info
///                         must not be attached to values of these types.
///   IsEffectivelyFinal  — Returns true if no subclass can exist at runtime.
///   RequiresStrictLockOrder — Returns 1 if the runtime requires strict
///                         monitor-stack nesting at materialization
///                         (HotSpot LM_LIGHTWEIGHT); 0 otherwise.
///   ElementBasicTypeOfArrayKlass — Given an array klass pointer, return the
///                         Java basic type of its elements encoded as a
///                         JBasicType integer (Boolean=0..Object=8). Returns
///                         JBasicType::Count (9) for non-array klasses or
///                         null/unknown inputs.
///   ArrayElementKlass    — Given an object-array klass pointer, return its
///                         element klass pointer. Returns 0 for primitive
///                         (type-array) klasses, for null inputs, or when
///                         the element klass is otherwise unavailable.
///   IsValueBased         — Returns true iff the klass carries the
///                         jdk.internal.ValueBased annotation (HotSpot's
///                         access_flags().is_value_based_class()). Used by
///                         PEA's foldCheckIfValueBased to decide whether a
///                         virtual receiver of jeandle.check_if_value_based
///                         should force-materialize (klass IS value-based —
///                         the runtime warning must fire on a real oop) or
///                         elide the check (klass is NOT value-based). For
///                         null/unresolved klass inputs the implementation
///                         must return false (PEA already gates the query
///                         on VObj.Klass != 0 and callback availability).
///                         Therefore false for a queried exact Klass means it
///                         is provably not value-based and the check is folded
///                         away; the null case is only defensive API behavior.
///   IsBoxed              — Returns the JBasicType integer of the boxed
///                         primitive if the klass is one of the eight
///                         autobox wrapper classes (java.lang.Boolean,
///                         Byte, Character, Short, Integer, Long, Float,
///                         Double); returns JBasicType::Count (9) for any
///                         other klass or null input. Currently UNUSED by
///                         partial escape analysis (the frontend does not
///                         inline the valueOf intrinsic that a boxing fold
///                         would depend on, per the "no special-
///                         optimization unsupported by the frontend" rule).
///                         It is wired into the callback table and recorded
///                         by the .cblog fixtures in anticipation of a
///                         future structural icmp-eq boxed-primitive fold
///                         mirroring Graal's VirtualBoxingNode +
///                         ObjectEqualsNode boxed path; until that lands it
///                         must stay conservatively "not boxed" for every
///                         PEA query.
///   HasFinalizer         — Returns true iff the klass has a non-trivial
///                         finalize() method (HotSpot's
///                         InstanceKlass::has_finalizer()). Mirrors
///                         Graal's NewInstanceNode + RegisterFinalizerNode
///                         interaction: a class with a finalizer must
///                         have its allocation actually executed at the
///                         original allocation site so HotSpot's
///                         finalizer registration runs, otherwise the
///                         finalize() method would never be invoked.
///                         processAllocation refuses to virtualize the alloc
///                         when this returns true. For null inputs the
///                         implementation must return false.
///   CanVirtualize        — Returns true iff the klass is safe to
///                         virtualize (no identity-sensitive runtime
///                         constraints). Mirrors Graal's
///                         MetaAccessExtensionProvider.canVirtualize.
///                         The JDK-side implementation enumerates
///                         identity-sensitive subtypes (java.lang.ref.
///                         Reference and Thread hierarchies) and returns
///                         false for those; everything else returns
///                         true. processAllocation refuses to virtualize
///                         when this returns false. For null inputs the
///                         implementation must return false (analogous
///                         to the value-based / boxed callbacks: a null
///                         klass cannot be proven safe).
///   GetConstantField   — Returns (HotSpot BasicType, raw value) for a
///                         foldable constant field. The BasicType is negative
///                         when the field is not foldable; the raw value is
///                         then recorded as zero. Otherwise the raw value is
///                         widened for integral primitives, contains the IEEE
///                         bit pattern for float/double, or is the stable oop
///                         id for object/array values (-1 for null).
///   GetOopHandleName
///                       — Returns the descriptive oop handle name (e.g.
///                         "oop_handle_Test_1") for a given oop id. The
///                         returned pointer remains valid for the duration
///                         of the compilation.
///   GetOopKlass         — Returns the actual runtime klass pointer of the
///                         constant oop with the given oop id, or 0 if it is
///                         unavailable. Pure (id -> klass).
///   GetKlassConstant    — Returns a stable compile-time Klass pointer constant
///                         for a known Klass, or 0 if unavailable. The VM
///                         records the Klass dependency before returning it.
///   GetJavaMirror       — Given a VM Klass pointer, returns the oop id of its
///                         Java mirror (the java.lang.Class object), or -1 if
///                         unavailable. Used by PEA's foldGetClass to fold
///                         jeandle.get_class on a virtual receiver (whose exact
///                         klass is statically known) to the constant Class
///                         mirror. Pure (Klass -> mirror oop id).
///   GetMirrorKlass      — For a constant java.lang.Class mirror, returns its
///                         represented reference Klass pointer, or 0 when the
///                         mirror represents a primitive type. Returns
///                         MirrorKlassUnavailable for a non-mirror or an
///                         unavailable value. Pure (id -> represented klass).
///   GetKlassLayoutHelper
///                       — Returns Klass::layout_helper() for a constant Klass
///                         pointer, or 0 if unavailable. Pure (klass ->
///                         layout helper).
///   IsKlassInitialized  — Returns true iff a constant Klass is an initialized
///                         instance klass. ConstantFieldFolding only acts on a
///                         true result because initialization is monotonic;
///                         false retains the dynamic initialization check.
///   IsOkToInline        — Given an inline scope id, call-site BCI, and callee
///                         Java method pointer, returns whether the VM allows
///                         this inline attempt.
///   GetInlineCalleeIR   — Given a callee Java method pointer, materializes its
///                         LLVM IR into the active module and returns whether
///                         the definition is available.
///   GetNewStatepointID  — Given an inlined call site's old statepoint id,
///                         returns a fresh statepoint id whose JVM callsite
///                         info is valid in the root method.
///   RecordInlineResult
///                       — Notifies the VM that an inline scope id / BCI /
///                         callee Java method pointer reached an LLVM inline
///                         result. The fourth argument is a
///                         JeandleInlineReason value: InlineSuccess means the
///                         inline completed, and the remaining values describe
///                         LLVM-side failure reasons. The VM handles callback
///                         failures before returning, so LLVM expects a true
///                         result.
///   RecordInliningComplete
///                       — Notifies the VM that the inline driver has finished
///                         materializing and inlining callees. The VM handles
///                         failures before returning, so LLVM expects a true
///                         result.
///                         "oop_handle_Test_1") for a given oop id.
///   GetCHAOptInfo       — Returns (constraint or holder, target method,
///                         packed deoptimization or target info, target method
///                         name) for CHA devirtualization. A zero first field
///                         means the call site cannot be optimized.
///   UpdateCallSite
///                       — Updates the call site to given destination.
///   GetProfileDevirtualizationInfo
///                       — Queries receiver profiles and target resolution in
///                         the VM using the call-site's inline scope and
///                         bytecode context. Returns a self-contained
///                         monomorphic or bimorphic optimization result, or
///                         empty if the call should remain virtual. The third
///                         field packs the deoptimization reason and accessor
///                         bits.
///   UpdateToStaticOptVirtualCall
///                       — Updates the call site to a static opt virtual call.
///                         This callback has side effects on jvm side.
///   GetSignatureAccessingKlass
///                       — Returns the signature accessing klass as a Klass
///                         pointer. This is the class-loader/access context
///                         used to esolve reference types in the method
///                         signature. It is not necessarily the same as the
///                         method holder.
///   GetSignatureArgType — Returns the HotSpot BasicType tag as int64_t.
///                         For index -1: the method return type.
///                         For index >= 0: the argument type at the zero-based
///                         ciSignature parameter index.
///                         The index excludes the receiver and is not a JVM
///                         stack-slot index.
///   GetSignatureArgTypeKlass
///                       — Returns the declared Klass pointer of a reference
///                         argument in the method signature.
///                         The index is a zero-based ciSignature parameter
///                         index, excluding the receiver and not a JVM
///                         stack-slot index.
///                         Callers must only query reference parameters.
///   GetSecondarySupers
///                       — Returns the secondary super klass pointers of the
///                       input klass

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
