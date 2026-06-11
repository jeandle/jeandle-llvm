//===- VMCallbackLog.cpp - VM Callback Recording & Replay -----------------===//
//
// Copyright (c) 2026, the Jeandle-LLVM Authors. All Rights Reserved.
//
// Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM
// Exceptions. See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#include "llvm/IR/Jeandle/VMCallbackLog.h"
#include "llvm/ADT/StringSwitch.h"
#include "llvm/Support/Error.h"
#include "llvm/Support/FileSystem.h"
#include "llvm/Support/MemoryBuffer.h"
#include "llvm/Support/raw_ostream.h"

#include <cstdlib>
#include <memory>
#include <tuple>
#include <utility>

using namespace llvm;
using namespace llvm::jeandle;

// =============================================================================
// Callback table — generated from ALL_JEANDLE_VM_CALLBACKS
// =============================================================================

#define JEANDLE_STRIP_PARENS(...) __VA_ARGS__

#define DEF_CALLBACK_TABLE_ENTRY(Name, RetType, ResType, Params, Args,         \
                                 ArgTypes, NumArgs)                            \
  T.push_back(CallbackInfo(#Name, {JEANDLE_STRIP_PARENS ArgTypes},             \
                           VMCallbackValueType::ResType));

static llvm::ArrayRef<CallbackInfo> getCallbackTable() {
  static const SmallVector<CallbackInfo, 6> Table = [] {
    SmallVector<CallbackInfo, 6> T;
    ALL_JEANDLE_VM_CALLBACKS(DEF_CALLBACK_TABLE_ENTRY)
    return T;
  }();
  return Table;
}

#undef DEF_CALLBACK_TABLE_ENTRY

// =============================================================================
// Thread-local active recorder
// =============================================================================

thread_local VMCallbackLogRecorder *VMCallbackLogRecorder::ActiveRecorder =
    nullptr;

// =============================================================================
// VMCallbackLogRecorder - RAII per-compilation recorder
// =============================================================================

VMCallbackLogRecorder::VMCallbackLogRecorder() {
  assert(ActiveRecorder == nullptr &&
         "Nested VMCallbackLogRecorder not allowed");
  ActiveRecorder = this;
}

VMCallbackLogRecorder::~VMCallbackLogRecorder() { ActiveRecorder = nullptr; }

void VMCallbackLogRecorder::recordIfNew(unsigned Kind, ArrayRef<int64_t> Args,
                                        int64_t Result) {
  CallbackKey Key{Kind, SmallVector<int64_t, 4>(Args.begin(), Args.end())};
  auto [It, Inserted] = Entries.try_emplace(Key, Result);
  if (!Inserted && It->second != Result) {
    const auto &Info = getCallbackTable()[Kind];
    std::string ArgStr;
    raw_string_ostream OS(ArgStr);
    for (size_t I = 0; I < Args.size(); ++I) {
      if (I > 0)
        OS << ", ";
      OS << Args[I];
    }
    report_fatal_error("VMCallbackLog purity violation: " + Twine(Info.Name) +
                       "(" + ArgStr + ") returned " + Twine(Result) +
                       ", previously " + Twine(It->second));
  }
}

Error VMCallbackLogRecorder::dump(StringRef FilePath) {
  std::error_code EC;
  raw_fd_ostream OS(FilePath, EC, sys::fs::OF_Text);
  if (EC)
    return createStringError(EC, "cannot open file '%s': %s",
                             FilePath.str().c_str(), EC.message().c_str());

  // Collect entries and sort by (Kind, Args) for deterministic output.
  SmallVector<std::pair<CallbackKey, int64_t>, 16> SortedEntries;
  for (const auto &KV : Entries)
    SortedEntries.emplace_back(KV.getFirst(), KV.getSecond());
  llvm::sort(SortedEntries, [](const auto &A, const auto &B) {
    return std::tie(A.first.Kind, A.first.Args) <
           std::tie(B.first.Kind, B.first.Args);
  });

  for (const auto &[Key, Result] : SortedEntries) {
    const auto &Info = getCallbackTable()[Key.Kind];
    OS << Info.Name;
    for (unsigned I = 0; I < Info.ArgTypes.size(); ++I) {
      OS << " ";
      switch (Info.ArgTypes[I]) {
      case VMCallbackValueType::Uintptr:
        OS << static_cast<uintptr_t>(Key.Args[I]);
        break;
      case VMCallbackValueType::Int:
        OS << static_cast<int>(Key.Args[I]);
        break;
      case VMCallbackValueType::Long:
        OS << static_cast<int64_t>(Key.Args[I]);
        break;
      case VMCallbackValueType::Bool:
        OS << (Key.Args[I] ? "true" : "false");
        break;
      }
    }
    OS << " = ";
    switch (Info.ResType) {
    case VMCallbackValueType::Bool:
      OS << (Result ? "true" : "false");
      break;
    case VMCallbackValueType::Uintptr:
      OS << static_cast<uintptr_t>(Result);
      break;
    case VMCallbackValueType::Int:
      OS << static_cast<int>(Result);
      break;
    case VMCallbackValueType::Long:
      OS << static_cast<int64_t>(Result);
      break;
    }
    OS << "\n";
  }

  if (OS.has_error())
    return createStringError("error writing file '%s'", FilePath.str().c_str());
  return Error::success();
}

// =============================================================================
// Recording trampolines — generated from ALL_JEANDLE_VM_CALLBACKS
// =============================================================================
//
// RECORD_CALLBACK(Name, RetType, (param-decls), (arg-names))
//   - Params is a parenthesized parameter declaration list
//   - Args is a parenthesized argument name list
//

static VMCallbacks RealCallbacks;

#define RECORD_CALLBACK(Name, RetType, Params, Args)                           \
  static RetType record##Name Params {                                         \
    RetType Result = RealCallbacks.Name(JEANDLE_STRIP_PARENS Args);            \
    if (auto *R = VMCallbackLogRecorder::getActiveRecorder())                  \
      R->recordIfNew(CK_##Name, encodeArgs(JEANDLE_STRIP_PARENS Args),         \
                     static_cast<int64_t>(Result));                            \
    return Result;                                                             \
  }

#define DEF_RECORD_CB(Name, RetType, ResType, Params, Args, ArgTypes, NumArgs) \
  RECORD_CALLBACK(Name, RetType, Params, Args)

ALL_JEANDLE_VM_CALLBACKS(DEF_RECORD_CB)

#undef DEF_RECORD_CB
#undef RECORD_CALLBACK

void jeandle::enableVMCallbackRecording() {
  static bool RecordingEnabled = false;
  if (RecordingEnabled)
    return;
  RecordingEnabled = true;

  const VMCallbacks *Current = getVMCallbacks();
  if (!Current)
    report_fatal_error("VMCallbacks must be registered before enabling "
                       "recording");

  RealCallbacks = *Current;

  VMCallbacks RecordingCallbacks;
#define DEF_RECORD_WIRING(Name, RetType, ResType, Params, Args, ArgTypes,      \
                          NumArgs)                                             \
  RecordingCallbacks.Name = &record##Name;
  ALL_JEANDLE_VM_CALLBACKS(DEF_RECORD_WIRING)
#undef DEF_RECORD_WIRING
  registerVMCallbacks(RecordingCallbacks);
}

// =============================================================================
// Replay
// =============================================================================

namespace {

struct ReplayData {
  DenseMap<CallbackKey, int64_t, CallbackKeyDenseMapInfo> Entries;
};

static std::unique_ptr<ReplayData> LogData;

/// Look up a callback result by (Kind, Args). Terminates if the log is
/// not initialized or the key is not found.
static int64_t lookupResult(unsigned Kind, ArrayRef<int64_t> Args,
                            const char *CallbackName) {
  if (!LogData) {
    report_fatal_error("VMCallbackLog replay not initialized at " +
                       Twine(CallbackName));
  }
  CallbackKey Key{Kind, SmallVector<int64_t, 4>(Args.begin(), Args.end())};
  auto It = LogData->Entries.find(Key);
  if (It == LogData->Entries.end()) {
    std::string ArgStr;
    raw_string_ostream OS(ArgStr);
    for (size_t I = 0; I < Args.size(); ++I) {
      if (I > 0)
        OS << ", ";
      OS << Args[I];
    }
    report_fatal_error("VMCallbackLog missing entry for " +
                       Twine(CallbackName) + "(" + ArgStr + ")");
  }
  return It->second;
}

// REPLAY_CALLBACK(Name, RetType, (param-decls), (arg-names))
// Same parenthesized-params pattern as RECORD_CALLBACK.
#define REPLAY_CALLBACK(Name, RetType, Params, Args)                           \
  static RetType replay##Name Params {                                         \
    int64_t RawResult =                                                        \
        lookupResult(CK_##Name, encodeArgs(JEANDLE_STRIP_PARENS Args), #Name); \
    return decodeVMCallbackValue<RetType>(RawResult);                          \
  }

#define DEF_REPLAY_CB(Name, RetType, ResType, Params, Args, ArgTypes, NumArgs) \
  REPLAY_CALLBACK(Name, RetType, Params, Args)

ALL_JEANDLE_VM_CALLBACKS(DEF_REPLAY_CB)

#undef DEF_REPLAY_CB
#undef REPLAY_CALLBACK

} // anonymous namespace

// =============================================================================
// Log file parser — descriptor-driven
// =============================================================================

/// Look up a callback kind by name. Returns getCallbackTable().size() if not
/// found.
static unsigned findCallbackKind(StringRef Name) {
  return StringSwitch<unsigned>(Name)
#define DEF_FIND_CB(Name, RetType, ResType, Params, Args, ArgTypes, NumArgs)   \
  .Case(#Name, CK_##Name)
      ALL_JEANDLE_VM_CALLBACKS(DEF_FIND_CB)
#undef DEF_FIND_CB
          .Default(getCallbackTable().size());
}

/// Parse a token according to its expected value type.
static std::optional<int64_t> parseValue(StringRef Token,
                                         VMCallbackValueType VT) {
  switch (VT) {
  case VMCallbackValueType::Bool: {
    if (Token == "true")
      return 1;
    if (Token == "false")
      return 0;
    // Also accept 0/1 for bool.
    unsigned long long Val;
    if (Token.getAsInteger(0, Val) || Val > 1)
      return std::nullopt;
    return static_cast<int64_t>(Val);
  }
  case VMCallbackValueType::Uintptr: {
    unsigned long long Val;
    if (Token.getAsInteger(0, Val))
      return std::nullopt;
    return static_cast<int64_t>(static_cast<uintptr_t>(Val));
  }
  case VMCallbackValueType::Int: {
    int Val;
    if (Token.getAsInteger(0, Val))
      return std::nullopt;
    return static_cast<int64_t>(Val);
  }
  case VMCallbackValueType::Long: {
    int64_t Val;
    if (Token.getAsInteger(0, Val))
      return std::nullopt;
    return Val;
  }
  }
  return std::nullopt;
}

static Error parseLogBuffer(
    StringRef Buffer,
    DenseMap<CallbackKey, int64_t, CallbackKeyDenseMapInfo> &Entries) {
  SmallVector<StringRef, 0> Lines;
  Buffer.split(Lines, '\n');

  for (size_t LineNum = 0; LineNum < Lines.size(); ++LineNum) {
    StringRef Line = Lines[LineNum].trim();

    // Skip empty lines and comments.
    if (Line.empty() || Line.starts_with("#"))
      continue;

    // Parse: <CallbackName> <arg1> [<arg2> ...] = <result>
    SmallVector<StringRef, 8> Tokens;
    Line.split(Tokens, ' ', /*MaxSplit=*/-1, /*KeepEmpty=*/false);

    if (Tokens.size() < 3)
      return createStringError("line %zu: too few tokens: '%s'", LineNum + 1,
                               Line.str().c_str());

    unsigned Kind = findCallbackKind(Tokens[0]);
    if (Kind >= getCallbackTable().size())
      return createStringError("line %zu: unknown callback: '%s'", LineNum + 1,
                               Tokens[0].str().c_str());

    const auto &Info = getCallbackTable()[Kind];

    // Find the '=' separator.
    size_t EqIdx = Tokens.size();
    for (size_t I = 1; I < Tokens.size(); ++I) {
      if (Tokens[I] == "=") {
        EqIdx = I;
        break;
      }
    }
    if (EqIdx >= Tokens.size() - 1)
      return createStringError("line %zu: missing '=' or result: '%s'",
                               LineNum + 1, Line.str().c_str());

    // Validate argument count.
    unsigned ParsedArgCount = EqIdx - 1;
    if (ParsedArgCount != Info.ArgTypes.size())
      return createStringError("line %zu: callback '%s' expects %zu "
                               "argument(s), got %u",
                               LineNum + 1, Info.Name, Info.ArgTypes.size(),
                               ParsedArgCount);

    // Parse arguments according to their declared types.
    SmallVector<int64_t, 4> Args;
    for (unsigned I = 0; I < Info.ArgTypes.size(); ++I) {
      auto Val = parseValue(Tokens[I + 1], Info.ArgTypes[I]);
      if (!Val)
        return createStringError("line %zu: invalid argument %u for '%s': '%s'",
                                 LineNum + 1, I + 1, Info.Name,
                                 Tokens[I + 1].str().c_str());
      Args.push_back(*Val);
    }

    // Parse result according to the callback's return type.
    StringRef ResultStr = Tokens[EqIdx + 1];
    auto Result = parseValue(ResultStr, Info.ResType);
    if (!Result)
      return createStringError("line %zu: invalid result for '%s': '%s'",
                               LineNum + 1, Info.Name, ResultStr.str().c_str());

    // Insert into map; error on conflicting duplicates.
    CallbackKey Key{Kind, SmallVector<int64_t, 4>(Args.begin(), Args.end())};
    auto [It, Inserted] = Entries.try_emplace(Key, *Result);
    if (!Inserted && It->second != *Result) {
      return createStringError(
          "line %zu: conflicting result for '%s': previously %lld, now %lld",
          LineNum + 1, Info.Name, static_cast<long long>(It->second),
          static_cast<long long>(*Result));
    }
  }

  return Error::success();
}

Error jeandle::loadAndRegisterVMCallbackLog(StringRef FilePath) {
  if (LogData != nullptr) {
    return createStringError("VMCallbackLog already loaded");
  }

  auto BufferOrErr = MemoryBuffer::getFileOrSTDIN(FilePath);
  if (std::error_code EC = BufferOrErr.getError())
    return createStringError(EC, "cannot open file '%s': %s",
                             FilePath.str().c_str(), EC.message().c_str());

  auto ParsedData = std::make_unique<ReplayData>();
  if (Error Err =
          parseLogBuffer(BufferOrErr.get()->getBuffer(), ParsedData->Entries))
    return Err;

  LogData = std::move(ParsedData);

  VMCallbacks ReplayCallbacks;
#define DEF_REPLAY_WIRING(Name, RetType, ResType, Params, Args, ArgTypes,      \
                          NumArgs)                                             \
  ReplayCallbacks.Name = &replay##Name;
  ALL_JEANDLE_VM_CALLBACKS(DEF_REPLAY_WIRING)
#undef DEF_REPLAY_WIRING
  registerVMCallbacks(ReplayCallbacks);

  return Error::success();
}

#undef JEANDLE_STRIP_PARENS
