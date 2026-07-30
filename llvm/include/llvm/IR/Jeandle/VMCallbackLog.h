//===- VMCallbackLog.h - VM Callback Recording & Replay -------------------===//
//
// Copyright (c) 2026, the Jeandle-LLVM Authors. All Rights Reserved.
//
// Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM
// Exceptions. See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//
//
// Provides mechanisms to record and replay VM callback invocations, enabling
// standalone testing of Jeandle LLVM passes (e.g., TypeCheckElimination)
// without a running JVM.
//
// Replay mode (--jeandle-vm-callback-log=<file>):
//   Loads a callback log file and registers replay callbacks that answer
//   queries from the recorded data. Lookups are by (CallbackKind, Args) key,
//   so replay is order-independent and deduplicated.
//
// Record mode (JVM-side):
//   enableVMCallbackRecording() installs recording trampolines over the
//   real VM callbacks. Each compilation creates a VMCallbackLogRecorder
//   (RAII) to scope the recording, and calls dump() to write the log.
//   Duplicate (Kind, Args) -> Result mappings are deduplicated; a
//   conflicting result for the same (Kind, Args) triggers a fatal error
//   (purity violation).
//
//===----------------------------------------------------------------------===//

#ifndef JEANDLE_VM_CALLBACK_LOG_H
#define JEANDLE_VM_CALLBACK_LOG_H

#include "llvm/ADT/DenseMap.h"
#include "llvm/ADT/Hashing.h"
#include "llvm/ADT/SmallVector.h"
#include "llvm/ADT/StringRef.h"
#include "llvm/IR/Jeandle/VMCallback.h"
#include "llvm/Support/Error.h"
#include "llvm/Support/ErrorHandling.h"

#include <cstdint>
#include <initializer_list>
#include <string>
#include <tuple>
#include <type_traits>
#include <variant>
#include <vector>

namespace llvm {
class Module;
} // namespace llvm

namespace llvm::jeandle {

// =============================================================================
// Callback schema descriptor
// =============================================================================

/// Describes the schema of a single VM callback.
/// Used to drive serialization, parsing, and validation.
struct CallbackInfo {
  const char *Name;
  llvm::SmallVector<VMCallbackValueType, 4> ArgTypes;
  VMCallbackValueType ResType;

  CallbackInfo(const char *N, std::initializer_list<VMCallbackValueType> AT,
               VMCallbackValueType RT)
      : Name(N), ArgTypes(AT), ResType(RT) {}
};

// =============================================================================
// Callback kind enum — generated from ALL_JEANDLE_VM_CALLBACKS
// =============================================================================
//
// To add a new callback, add a row to ALL_JEANDLE_VM_CALLBACKS in
// VMCallback.h, then implement the JDK-side function in
// jeandleVMCallback.cpp and wire it in register_jeandle_vm_callbacks().
//

#define DEF_CALLBACK_KIND(Name, RetType, ResType, Params, Args, ArgTypes,      \
                          NumArgs)                                             \
  CK_##Name,

enum CallbackKind : unsigned { ALL_JEANDLE_VM_CALLBACKS(DEF_CALLBACK_KIND) };

#undef DEF_CALLBACK_KIND

// =============================================================================
// CallbackValue — unified type for callback arguments and results
// =============================================================================

/// A single callback value. Arrays and tuples are represented structurally, so
/// nested values stay typed through record/replay instead of being packed into
/// an ad-hoc string.
struct CallbackValue {
  // Keep these values aligned with StorageType's alternative indices.
  enum class Kind : uint8_t { Number, String, Array, Tuple };

private:
  struct Array {
    std::vector<CallbackValue> Elements;

    bool operator==(const Array &O) const { return Elements == O.Elements; }
    bool operator<(const Array &O) const { return Elements < O.Elements; }
  };
  struct Tuple {
    std::vector<CallbackValue> Elements;

    bool operator==(const Tuple &O) const { return Elements == O.Elements; }
    bool operator<(const Tuple &O) const { return Elements < O.Elements; }
  };

  using StorageType = std::variant<int64_t, std::string, Array, Tuple>;
  StorageType Storage = int64_t{0};

public:
  static CallbackValue fromNum(int64_t V) {
    CallbackValue Result;
    Result.Storage = V;
    return Result;
  }
  static CallbackValue fromStr(StringRef S) {
    CallbackValue Result;
    Result.Storage = S.str();
    return Result;
  }
  static CallbackValue fromArray(std::vector<CallbackValue> V) {
    CallbackValue Result;
    Result.Storage = Array{std::move(V)};
    return Result;
  }
  static CallbackValue fromTuple(std::vector<CallbackValue> V) {
    CallbackValue Result;
    Result.Storage = Tuple{std::move(V)};
    return Result;
  }

  bool isNumber() const { return std::holds_alternative<int64_t>(Storage); }
  bool isString() const { return std::holds_alternative<std::string>(Storage); }
  bool isArray() const { return std::holds_alternative<Array>(Storage); }
  bool isTuple() const { return std::holds_alternative<Tuple>(Storage); }

  int64_t number() const { return std::get<int64_t>(Storage); }
  StringRef string() const { return std::get<std::string>(Storage); }
  const std::vector<CallbackValue> &array() const {
    return std::get<Array>(Storage).Elements;
  }
  const std::vector<CallbackValue> &tuple() const {
    return std::get<Tuple>(Storage).Elements;
  }

  bool operator==(const CallbackValue &O) const { return Storage == O.Storage; }
  bool operator!=(const CallbackValue &O) const { return !(*this == O); }
  bool operator<(const CallbackValue &O) const { return Storage < O.Storage; }
};

// =============================================================================
// Callback key for map-based lookup
// =============================================================================

/// Key for deduplicated map-based recording and replay of VM callbacks.
/// Each unique (Kind, Args) pair maps to exactly one Result, since all VM
/// callbacks are pure functions.
struct CallbackKey {
  unsigned Kind; // CallbackKind enum value
  SmallVector<CallbackValue, 4> Args;

  bool operator==(const CallbackKey &Other) const {
    return Kind == Other.Kind && Args == Other.Args;
  }
};

/// DenseMapInfo for CallbackKey, using sentinel Kind values that cannot
/// collide with valid CallbackKind enum values.
struct CallbackKeyDenseMapInfo {
  static inline CallbackKey getEmptyKey() {
    return {DenseMapInfo<unsigned>::getEmptyKey(), {}};
  }
  static inline CallbackKey getTombstoneKey() {
    return {DenseMapInfo<unsigned>::getTombstoneKey(), {}};
  }
  static hash_code hashCallbackValue(const CallbackValue &V) {
    if (V.isNumber())
      return hash_combine(static_cast<unsigned>(CallbackValue::Kind::Number),
                          V.number());
    if (V.isString())
      return hash_combine(
          static_cast<unsigned>(CallbackValue::Kind::String),
          hash_combine_range(V.string().begin(), V.string().end()));
    if (V.isArray()) {
      hash_code H =
          hash_combine(static_cast<unsigned>(CallbackValue::Kind::Array));
      for (const CallbackValue &E : V.array())
        H = hash_combine(H, hashCallbackValue(E));
      return H;
    }
    assert(V.isTuple());
    hash_code H =
        hash_combine(static_cast<unsigned>(CallbackValue::Kind::Tuple));
    for (const CallbackValue &E : V.tuple())
      H = hash_combine(H, hashCallbackValue(E));
    return H;
  }
  static unsigned getHashValue(const CallbackKey &Key) {
    unsigned H = Key.Kind;
    for (const auto &A : Key.Args)
      H = hash_combine(H, hashCallbackValue(A));
    return H;
  }
  static bool isEqual(const CallbackKey &LHS, const CallbackKey &RHS) {
    return LHS == RHS;
  }
};

// =============================================================================
// VMCallbackLogRecorder
// =============================================================================

/// RAII recorder that scopes VM callback recording to a single compilation.
///
/// On construction, sets the thread-local active recorder; on destruction,
/// clears it. Concurrent compilations on different threads each create their
/// own VMCallbackLogRecorder, so their logs don't interleave.
class VMCallbackLogRecorder {
public:
  VMCallbackLogRecorder();
  ~VMCallbackLogRecorder();

  VMCallbackLogRecorder(const VMCallbackLogRecorder &) = delete;
  VMCallbackLogRecorder &operator=(const VMCallbackLogRecorder &) = delete;

  /// Write the recorded callback log to a file.
  /// Entries are deduplicated and sorted by (Kind, Args) for determinism.
  /// Returns Error::success() on success, or an error on failure.
  Error dump(StringRef FilePath);

  /// Get the active recorder for the current thread (used by trampolines).
  static VMCallbackLogRecorder *getActiveRecorder() { return ActiveRecorder; }

  /// Record a callback invocation result. If the (Kind, Args) key already
  /// exists with a different Result, report a fatal error (purity violation).
  /// If the key already exists with the same Result, this is a no-op (dedup).
  void recordIfNew(unsigned Kind, ArrayRef<CallbackValue> Args,
                   CallbackValue Result);

private:
  DenseMap<CallbackKey, CallbackValue, CallbackKeyDenseMapInfo> Entries;
  static thread_local VMCallbackLogRecorder *ActiveRecorder;
};

// =============================================================================
// Encoding/decoding helpers for recording and replay trampolines
// =============================================================================

template <typename T> struct VMCallbackValueCodec;

template <> struct VMCallbackValueCodec<bool> {
  static CallbackValue encode(bool V) {
    return CallbackValue::fromNum(V ? 1 : 0);
  }
  static bool decode(const CallbackValue &V) {
    assert(V.isNumber());
    return V.number() != 0;
  }
};
template <> struct VMCallbackValueCodec<int> {
  static CallbackValue encode(int V) { return CallbackValue::fromNum(V); }
  static int decode(const CallbackValue &V) {
    assert(V.isNumber());
    return static_cast<int>(V.number());
  }
};
template <> struct VMCallbackValueCodec<int64_t> {
  static CallbackValue encode(int64_t V) { return CallbackValue::fromNum(V); }
  static int64_t decode(const CallbackValue &V) {
    assert(V.isNumber());
    return V.number();
  }
};
template <> struct VMCallbackValueCodec<uintptr_t> {
  static CallbackValue encode(uintptr_t V) {
    return CallbackValue::fromNum(static_cast<int64_t>(V));
  }
  static uintptr_t decode(const CallbackValue &V) {
    assert(V.isNumber());
    return static_cast<uintptr_t>(V.number());
  }
};
template <> struct VMCallbackValueCodec<std::string> {
  static CallbackValue encode(const std::string &V) {
    return CallbackValue::fromStr(V);
  }
  static std::string decode(const CallbackValue &V) {
    assert(V.isString());
    return V.string().str();
  }
};

/// A homogeneous callback array has dynamic length. Its element codec is
/// compile-time selected; the iteration is intentionally runtime-sized.
template <typename T> struct VMCallbackValueCodec<std::vector<T>> {
  static CallbackValue encode(const std::vector<T> &V) {
    std::vector<CallbackValue> Elements;
    Elements.reserve(V.size());
    for (const T &E : V)
      Elements.push_back(VMCallbackValueCodec<T>::encode(E));
    return CallbackValue::fromArray(std::move(Elements));
  }
  static std::vector<T> decode(const CallbackValue &V) {
    assert(V.isArray());
    std::vector<T> Elements;
    Elements.reserve(V.array().size());
    for (const CallbackValue &E : V.array())
      Elements.push_back(VMCallbackValueCodec<T>::decode(E));
    return Elements;
  }
};

template <typename... Ts> struct VMCallbackValueCodec<std::tuple<Ts...>> {
  using Tuple = std::tuple<Ts...>;
  static CallbackValue encode(const Tuple &V) {
    std::vector<CallbackValue> Elements;
    Elements.reserve(sizeof...(Ts));
    std::apply(
        [&](const auto &...E) {
          (Elements.push_back(
               VMCallbackValueCodec<std::decay_t<decltype(E)>>::encode(E)),
           ...);
        },
        V);
    return CallbackValue::fromTuple(std::move(Elements));
  }
  static Tuple decode(const CallbackValue &V) {
    assert(V.isTuple() && V.tuple().size() == sizeof...(Ts) &&
           "callback tuple shape does not match its declared return type");
    return decodeImpl(V, std::index_sequence_for<Ts...>{});
  }

private:
  template <size_t... I>
  static Tuple decodeImpl(const CallbackValue &V, std::index_sequence<I...>) {
    return Tuple{VMCallbackValueCodec<Ts>::decode(V.tuple()[I])...};
  }
};

/// Encode variadic args into a vector for replay matching.
template <typename... Ts>
inline SmallVector<CallbackValue, 4> encodeArgs(Ts... Args) {
  return {VMCallbackValueCodec<std::decay_t<Ts>>::encode(Args)...};
}

// =============================================================================
// Public API
// =============================================================================

/// Parse a VM callback log file and register replay callbacks.
/// Entries are looked up by (CallbackKind, Args) key during replay.
/// Duplicate entries with the same key and result are silently accepted;
/// conflicting duplicates (same key, different result) produce an error.
/// InlineCalleeIRPath is used to replay GetInlineCalleeIR side effects.
/// Returns Error::success() on success, or an error on failure.
Error loadAndRegisterVMCallbackLog(StringRef FilePath,
                                   StringRef InlineCalleeIRPath);

using InlineCalleeIRReplayMaterializerFn =
    void (*)(Module &M, StringRef InlineCalleeIRPath, uintptr_t CalleeMethod);

/// Register the materializer used by GetInlineCalleeIR replay. The VM callback
/// log layer owns the replay decision/result, while the Jeandle inliner owns
/// the actual IR parsing/linking because it has the destination module and the
/// right component dependencies.
void registerInlineCalleeIRReplayMaterializer(
    InlineCalleeIRReplayMaterializerFn Materializer);

/// Sets the current destination module while replay callbacks are executing.
/// GetInlineCalleeIR replay uses this to materialize callee IR from the
/// companion *_inline_callees.ll replay module into the module being optimized.
class VMCallbackReplayModuleScope {
public:
  explicit VMCallbackReplayModuleScope(Module &M);
  ~VMCallbackReplayModuleScope();

  VMCallbackReplayModuleScope(const VMCallbackReplayModuleScope &) = delete;
  VMCallbackReplayModuleScope &
  operator=(const VMCallbackReplayModuleScope &) = delete;
};

/// Install recording trampolines over the currently registered VM callbacks.
/// Must be called after registerVMCallbacks(). The trampolines delegate to
/// the real callbacks and also record invocations per-compilation via
/// VMCallbackLogRecorder. Call once during compiler initialization.
void enableVMCallbackRecording();

} // namespace llvm::jeandle

#endif // JEANDLE_VM_CALLBACK_LOG_H
