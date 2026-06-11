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
#include "llvm/IR/Jeandle/VMCallback.h"
#include "llvm/Support/Error.h"
#include "llvm/Support/ErrorHandling.h"

#include <cstdint>
#include <initializer_list>

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
// Callback key for map-based lookup
// =============================================================================

/// Key for deduplicated map-based recording and replay of VM callbacks.
/// Each unique (Kind, Args) pair maps to exactly one Result, since all VM
/// callbacks are pure functions.
struct CallbackKey {
  unsigned Kind; // CallbackKind enum value
  SmallVector<int64_t, 4> Args;

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
  static unsigned getHashValue(const CallbackKey &Key) {
    return hash_combine(Key.Kind,
                        hash_combine_range(Key.Args.begin(), Key.Args.end()));
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
  void recordIfNew(unsigned Kind, ArrayRef<int64_t> Args, int64_t Result);

private:
  DenseMap<CallbackKey, int64_t, CallbackKeyDenseMapInfo> Entries;
  static thread_local VMCallbackLogRecorder *ActiveRecorder;
};

// =============================================================================
// Encoding/decoding helpers for recording and replay trampolines
// =============================================================================

template <typename T> inline int64_t encodeVMCallbackValue(T V);
template <> inline int64_t encodeVMCallbackValue<uintptr_t>(uintptr_t V) {
  return static_cast<int64_t>(V);
}
template <> inline int64_t encodeVMCallbackValue<int>(int V) {
  return static_cast<int64_t>(V);
}
template <> inline int64_t encodeVMCallbackValue<int64_t>(int64_t V) {
  return V;
}
template <> inline int64_t encodeVMCallbackValue<bool>(bool V) {
  return V ? 1 : 0;
}

template <typename T> inline T decodeVMCallbackValue(int64_t V);
template <> inline bool decodeVMCallbackValue<bool>(int64_t V) {
  return V != 0;
}
template <> inline uintptr_t decodeVMCallbackValue<uintptr_t>(int64_t V) {
  return static_cast<uintptr_t>(V);
}
template <> inline int decodeVMCallbackValue<int>(int64_t V) {
  return static_cast<int>(V);
}
template <> inline int64_t decodeVMCallbackValue<int64_t>(int64_t V) {
  return V;
}

/// Encode variadic args into a vector for replay matching.
template <typename... Ts>
inline SmallVector<int64_t, 4> encodeArgs(Ts... Args) {
  return {encodeVMCallbackValue(Args)...};
}

// =============================================================================
// Public API
// =============================================================================

/// Parse a VM callback log file and register replay callbacks.
/// Entries are looked up by (CallbackKind, Args) key during replay.
/// Duplicate entries with the same key and result are silently accepted;
/// conflicting duplicates (same key, different result) produce an error.
/// Returns Error::success() on success, or an error on failure.
Error loadAndRegisterVMCallbackLog(StringRef FilePath);

/// Install recording trampolines over the currently registered VM callbacks.
/// Must be called after registerVMCallbacks(). The trampolines delegate to
/// the real callbacks and also record invocations per-compilation via
/// VMCallbackLogRecorder. Call once during compiler initialization.
void enableVMCallbackRecording();

} // namespace llvm::jeandle

#endif // JEANDLE_VM_CALLBACK_LOG_H
