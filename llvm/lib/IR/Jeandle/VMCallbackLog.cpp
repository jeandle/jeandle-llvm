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
// Helpers for formatting CallbackValue in error messages
// =============================================================================

static void formatString(raw_ostream &OS, StringRef S) {
  static constexpr char Hex[] = "0123456789abcdef";
  OS << '"';
  for (unsigned char C : S.bytes()) {
    switch (C) {
    case '\\':
      OS << "\\\\";
      break;
    case '"':
      OS << "\\\"";
      break;
    case '\n':
      OS << "\\n";
      break;
    case '\r':
      OS << "\\r";
      break;
    case '\t':
      OS << "\\t";
      break;
    default:
      if (C < 0x20 || C == 0x7f)
        OS << "\\x" << Hex[C >> 4] << Hex[C & 0x0f];
      else
        OS << static_cast<char>(C);
    }
  }
  OS << '"';
}

static void formatValue(raw_ostream &OS, const CallbackValue &V) {
  if (V.isNumber()) {
    OS << V.number();
  } else if (V.isString()) {
    formatString(OS, V.string());
  } else if (V.isArray()) {
    OS << "[";
    for (size_t I = 0; I < V.array().size(); ++I) {
      if (I != 0)
        OS << ", ";
      formatValue(OS, V.array()[I]);
    }
    OS << "]";
  } else {
    OS << "(";
    for (size_t I = 0; I < V.tuple().size(); ++I) {
      if (I != 0)
        OS << ", ";
      formatValue(OS, V.tuple()[I]);
    }
    OS << ")";
  }
}

static void formatArgList(raw_string_ostream &OS,
                          ArrayRef<CallbackValue> Args) {
  for (size_t I = 0; I < Args.size(); ++I) {
    if (I > 0)
      OS << ", ";
    formatValue(OS, Args[I]);
  }
}

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

void VMCallbackLogRecorder::recordIfNew(unsigned Kind,
                                        ArrayRef<CallbackValue> Args,
                                        CallbackValue Result) {
  CallbackKey Key{Kind,
                  SmallVector<CallbackValue, 4>(Args.begin(), Args.end())};
  auto [It, Inserted] = Entries.try_emplace(Key, Result);
  if (!Inserted && It->second != Result) {
    const auto &Info = getCallbackTable()[Kind];
    std::string ArgStr, PrevStr, CurStr;
    raw_string_ostream ArgOS(ArgStr);
    raw_string_ostream PrevOS(PrevStr);
    raw_string_ostream CurOS(CurStr);
    formatArgList(ArgOS, Args);
    formatValue(PrevOS, It->second);
    formatValue(CurOS, Result);
    report_fatal_error("VMCallbackLog purity violation: " + Twine(Info.Name) +
                       "(" + ArgStr + ") returned " + CurStr + ", previously " +
                       PrevStr);
  }
}

Error VMCallbackLogRecorder::dump(StringRef FilePath) {
  std::error_code EC;
  raw_fd_ostream OS(FilePath, EC, sys::fs::OF_Text);
  if (EC)
    return createStringError(EC, "cannot open file '%s': %s",
                             FilePath.str().c_str(), EC.message().c_str());

  // Collect entries sorted by (Kind, Args) for determinism.
  SmallVector<CallbackKey, 20> SortedKeys;
  for (const auto &KV : Entries)
    SortedKeys.push_back(KV.getFirst());

  llvm::sort(SortedKeys, [](const CallbackKey &A, const CallbackKey &B) {
    if (A.Kind != B.Kind)
      return A.Kind < B.Kind;
    return A.Args < B.Args;
  });

  for (const auto &Key : SortedKeys) {
    const auto &Val = Entries.lookup(Key);
    const auto &Info = getCallbackTable()[Key.Kind];

    OS << Info.Name;
    for (unsigned I = 0; I < Info.ArgTypes.size(); ++I) {
      OS << " ";
      switch (Info.ArgTypes[I]) {
      case VMCallbackValueType::Bool:
        OS << (Key.Args[I].number() ? "true" : "false");
        break;
      case VMCallbackValueType::Int:
        OS << static_cast<int>(Key.Args[I].number());
        break;
      case VMCallbackValueType::Long:
        OS << static_cast<int64_t>(Key.Args[I].number());
        break;
      case VMCallbackValueType::Uintptr:
        OS << static_cast<uintptr_t>(Key.Args[I].number());
        break;
      case VMCallbackValueType::String:
        formatString(OS, Key.Args[I].string());
        break;
      case VMCallbackValueType::Array:
        formatValue(OS, Key.Args[I]);
        break;
      case VMCallbackValueType::Tuple:
        formatValue(OS, Key.Args[I]);
        break;
      }
    }
    OS << " = ";
    if (Val.isNumber()) {
      switch (Info.ResType) {
      case VMCallbackValueType::Bool:
        OS << (Val.number() ? "true" : "false");
        break;
      case VMCallbackValueType::Int:
        OS << static_cast<int>(Val.number());
        break;
      case VMCallbackValueType::Long:
        OS << static_cast<int64_t>(Val.number());
        break;
      case VMCallbackValueType::Uintptr:
        OS << static_cast<uintptr_t>(Val.number());
        break;
      case VMCallbackValueType::String:
        break;
      case VMCallbackValueType::Array:
        llvm_unreachable("array result must have array CallbackValue");
      case VMCallbackValueType::Tuple:
        llvm_unreachable("tuple result must have tuple CallbackValue");
      }
    } else if (Val.isString()) {
      formatString(OS, Val.string());
    } else if (Val.isArray()) {
      formatValue(OS, Val);
    } else {
      assert(Val.isTuple());
      formatValue(OS, Val);
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
                     VMCallbackValueCodec<RetType>::encode(Result));           \
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
  DenseMap<CallbackKey, CallbackValue, CallbackKeyDenseMapInfo> Entries;
  std::string InlineCalleeIRPath;
};

static std::unique_ptr<ReplayData> LogData;
static thread_local Module *CurrentReplayDestModule = nullptr;
static InlineCalleeIRReplayMaterializerFn InlineCalleeIRReplayMaterializer =
    nullptr;

static void materializeInlineCalleeIR(uintptr_t CalleeMethod) {
  if (!CurrentReplayDestModule)
    report_fatal_error("VMCallbackLog GetInlineCalleeIR replay has no active "
                       "destination module");

  if (!LogData)
    report_fatal_error("VMCallbackLog replay not initialized");

  if (!InlineCalleeIRReplayMaterializer)
    report_fatal_error("VMCallbackLog GetInlineCalleeIR replay has no inline "
                       "callee IR materializer");

  InlineCalleeIRReplayMaterializer(*CurrentReplayDestModule,
                                   LogData->InlineCalleeIRPath, CalleeMethod);
}

/// Look up a callback result by (Kind, Args). Returns a reference into the
/// long-lived log data; std::string replay results are copied from it.
/// Terminates if the log is not initialized or the key is not found.
static const CallbackValue &lookupValue(unsigned Kind,
                                        ArrayRef<CallbackValue> Args,
                                        const char *CallbackName) {
  if (!LogData) {
    report_fatal_error("VMCallbackLog replay not initialized at " +
                       Twine(CallbackName));
  }
  CallbackKey Key{Kind,
                  SmallVector<CallbackValue, 4>(Args.begin(), Args.end())};
  auto It = LogData->Entries.find(Key);
  if (It == LogData->Entries.end()) {
    std::string ArgStr;
    raw_string_ostream OS(ArgStr);
    formatArgList(OS, Args);
    report_fatal_error("VMCallbackLog missing entry for " +
                       Twine(CallbackName) + "(" + ArgStr + ")");
  }
  return It->second; // returns reference to map-owned value
}

// =============================================================================
// Replay dispatch
// =============================================================================

static void handleReplaySideEffects(unsigned Kind, ArrayRef<CallbackValue> Args,
                                    const CallbackValue &RawResult) {
  switch (Kind) {
  case CK_GetInlineCalleeIR:
    if (!VMCallbackValueCodec<bool>::decode(RawResult))
      return;
    assert(Args.size() == 1 && "GetInlineCalleeIR expects one argument");
    assert(Args[0].isNumber() && "GetInlineCalleeIR expects numeric method id");
    materializeInlineCalleeIR(VMCallbackValueCodec<uintptr_t>::decode(Args[0]));
    return;

  default:
    return;
  }
}

template <typename T>
static T fetchReplayedResult(unsigned Kind, ArrayRef<CallbackValue> Args,
                             const char *Name) {
  const CallbackValue &RawResult = lookupValue(Kind, Args, Name);
  handleReplaySideEffects(Kind, Args, RawResult);
  return VMCallbackValueCodec<T>::decode(RawResult);
}

// REPLAY_CALLBACK(Name, RetType, (param-decls), (arg-names))
// Same parenthesized-params pattern as RECORD_CALLBACK.
#define REPLAY_CALLBACK(Name, RetType, Params, Args)                           \
  static RetType replay##Name Params {                                         \
    return fetchReplayedResult<RetType>(                                       \
        CK_##Name, encodeArgs(JEANDLE_STRIP_PARENS Args), #Name);              \
  }

#define DEF_REPLAY_CB(Name, RetType, ResType, Params, Args, ArgTypes, NumArgs) \
  REPLAY_CALLBACK(Name, RetType, Params, Args)

ALL_JEANDLE_VM_CALLBACKS(DEF_REPLAY_CB)

#undef DEF_REPLAY_CB
#undef REPLAY_CALLBACK

} // anonymous namespace

llvm::jeandle::VMCallbackReplayModuleScope::VMCallbackReplayModuleScope(
    Module &M) {
  assert(!CurrentReplayDestModule &&
         "Nested VMCallbackReplayModuleScope is not supported");
  CurrentReplayDestModule = &M;
}

llvm::jeandle::VMCallbackReplayModuleScope::~VMCallbackReplayModuleScope() {
  CurrentReplayDestModule = nullptr;
}

void llvm::jeandle::registerInlineCalleeIRReplayMaterializer(
    InlineCalleeIRReplayMaterializerFn Materializer) {
  InlineCalleeIRReplayMaterializer = Materializer;
}

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

/// Parse a numeric token according to its expected value type.
static std::optional<int64_t> parseNumericToken(StringRef Token,
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
  case VMCallbackValueType::Uintptr: {
    unsigned long long Val;
    if (Token.getAsInteger(0, Val))
      return std::nullopt;
    return static_cast<int64_t>(static_cast<uintptr_t>(Val));
  }
  case VMCallbackValueType::String:
  case VMCallbackValueType::Array:
  case VMCallbackValueType::Tuple:
    // Structured and string tokens are handled separately by parseArgToken.
    return std::nullopt;
  }
  return std::nullopt;
}

/// Parse a self-describing value: number, quoted string, parenthesized tuple,
/// or bracketed array. Scalar elements use their canonical numeric form.
static std::optional<std::pair<std::string, size_t>>
parseStringLiteral(StringRef Str, size_t Pos) {
  if (Pos >= Str.size() || Str[Pos] != '"')
    return std::nullopt;

  std::string Result;
  for (++Pos; Pos < Str.size(); ++Pos) {
    char C = Str[Pos];
    if (C == '"')
      return std::make_pair(std::move(Result), Pos + 1);
    if (C != '\\') {
      Result.push_back(C);
      continue;
    }
    if (++Pos == Str.size())
      return std::nullopt;
    switch (Str[Pos]) {
    case '\\':
      Result.push_back('\\');
      break;
    case '"':
      Result.push_back('"');
      break;
    case 'n':
      Result.push_back('\n');
      break;
    case 'r':
      Result.push_back('\r');
      break;
    case 't':
      Result.push_back('\t');
      break;
    case 'x': {
      if (Pos + 2 >= Str.size())
        return std::nullopt;
      auto HexValue = [](char Digit) -> int {
        if (Digit >= '0' && Digit <= '9')
          return Digit - '0';
        if (Digit >= 'a' && Digit <= 'f')
          return Digit - 'a' + 10;
        if (Digit >= 'A' && Digit <= 'F')
          return Digit - 'A' + 10;
        return -1;
      };
      int High = HexValue(Str[Pos + 1]);
      int Low = HexValue(Str[Pos + 2]);
      if (High < 0 || Low < 0)
        return std::nullopt;
      Result.push_back(static_cast<char>((High << 4) | Low));
      Pos += 2;
      break;
    }
    default:
      return std::nullopt;
    }
  }
  return std::nullopt;
}

static std::optional<std::pair<CallbackValue, size_t>>
parseStructuredValue(StringRef Str, size_t Pos) {
  while (Pos < Str.size() && (Str[Pos] == ' ' || Str[Pos] == '\t'))
    ++Pos;
  if (Pos >= Str.size())
    return std::nullopt;

  if (Str[Pos] == '"') {
    auto String = parseStringLiteral(Str, Pos);
    if (!String)
      return std::nullopt;
    return std::make_pair(CallbackValue::fromStr(String->first),
                          String->second);
  }

  if (Str[Pos] == '(' || Str[Pos] == '[') {
    const char Closing = Str[Pos] == '(' ? ')' : ']';
    const bool IsArray = Str[Pos] == '[';
    std::vector<CallbackValue> Elements;
    ++Pos;
    while (true) {
      while (Pos < Str.size() && (Str[Pos] == ' ' || Str[Pos] == '\t'))
        ++Pos;
      if (Pos >= Str.size())
        return std::nullopt;
      if (Str[Pos] == Closing)
        return std::make_pair(
            IsArray ? CallbackValue::fromArray(std::move(Elements))
                    : CallbackValue::fromTuple(std::move(Elements)),
            Pos + 1);
      auto Element = parseStructuredValue(Str, Pos);
      if (!Element)
        return std::nullopt;
      Elements.push_back(std::move(Element->first));
      Pos = Element->second;
      while (Pos < Str.size() && (Str[Pos] == ' ' || Str[Pos] == '\t'))
        ++Pos;
      if (Pos >= Str.size() || (Str[Pos] != ',' && Str[Pos] != Closing))
        return std::nullopt;
      if (Str[Pos] == ',')
        ++Pos;
    }
  }

  size_t TokEnd = Pos;
  while (TokEnd < Str.size() && Str[TokEnd] != ' ' && Str[TokEnd] != '\t' &&
         Str[TokEnd] != ',' && Str[TokEnd] != ')' && Str[TokEnd] != ']')
    ++TokEnd;
  int64_t Number;
  if (Str.substr(Pos, TokEnd - Pos).getAsInteger(0, Number))
    return std::nullopt;
  return std::make_pair(CallbackValue::fromNum(Number), TokEnd);
}

/// Parse a single argument token from `Str` starting at position `Pos`.
/// - For String type: expects a double-quoted token.
/// - For numeric types: expects an unquoted token.
/// Returns the parsed CallbackValue and advances `Pos` past the token.
/// Returns std::nullopt on parse error.
static std::optional<std::pair<CallbackValue, size_t>>
parseArgToken(StringRef Str, size_t Pos, VMCallbackValueType VT) {
  // Skip leading whitespace.
  while (Pos < Str.size() && (Str[Pos] == ' ' || Str[Pos] == '\t'))
    ++Pos;
  if (Pos >= Str.size())
    return std::nullopt;

  if (VT != VMCallbackValueType::String && VT != VMCallbackValueType::Array &&
      VT != VMCallbackValueType::Tuple) {
    size_t TokEnd = Pos;
    while (TokEnd < Str.size() && Str[TokEnd] != ' ' && Str[TokEnd] != '\t')
      ++TokEnd;
    auto Val = parseNumericToken(Str.substr(Pos, TokEnd - Pos), VT);
    if (!Val)
      return std::nullopt;
    return std::make_pair(CallbackValue::fromNum(*Val), TokEnd);
  }

  if (VT == VMCallbackValueType::String) {
    auto String = parseStringLiteral(Str, Pos);
    if (!String)
      return std::nullopt;
    return std::make_pair(CallbackValue::fromStr(String->first),
                          String->second);
  }
  if (VT == VMCallbackValueType::Array) {
    auto Value = parseStructuredValue(Str, Pos);
    if (!Value || !Value->first.isArray())
      return std::nullopt;
    return Value;
  }
  if (VT == VMCallbackValueType::Tuple) {
    auto Value = parseStructuredValue(Str, Pos);
    if (!Value || !Value->first.isTuple())
      return std::nullopt;
    return Value;
  }

  llvm_unreachable("unknown VMCallbackValueType");
}

static Error parseLogBuffer(
    StringRef Buffer,
    DenseMap<CallbackKey, CallbackValue, CallbackKeyDenseMapInfo> &Entries) {
  SmallVector<StringRef, 0> Lines;
  Buffer.split(Lines, '\n');

  for (size_t LineNum = 0; LineNum < Lines.size(); ++LineNum) {
    StringRef Line = Lines[LineNum].trim();

    // Skip empty lines and comments.
    if (Line.empty() || Line.starts_with("#"))
      continue;

    unsigned Kind = findCallbackKind(
        Line.take_while([](char C) { return C != ' ' && C != '\t'; }));
    if (Kind >= getCallbackTable().size())
      return createStringError("line %zu: unknown callback: '%s'", LineNum + 1,
                               Line.str().c_str());

    const auto &Info = getCallbackTable()[Kind];

    // Find " = " to separate args from result.
    size_t EqPos = Line.find(" = ");
    if (EqPos == StringRef::npos)
      return createStringError("line %zu: missing ' = ': '%s'", LineNum + 1,
                               Line.str().c_str());

    // Extract the arg portion (between callback name and " = ").
    StringRef NameAndArgs = Line.substr(0, EqPos);
    StringRef ArgPart;
    size_t FirstSpace = NameAndArgs.find(' ');
    if (FirstSpace != StringRef::npos)
      ArgPart = NameAndArgs.substr(FirstSpace + 1);

    // Parse args token by token, handling quoted strings for String type.
    SmallVector<CallbackValue, 4> Args;
    if (!ArgPart.empty()) {
      size_t Pos = 0;
      for (unsigned I = 0; I < Info.ArgTypes.size(); ++I) {
        auto Parsed = parseArgToken(ArgPart, Pos, Info.ArgTypes[I]);
        if (!Parsed)
          return createStringError("line %zu: invalid argument %u for '%s'",
                                   LineNum + 1, I + 1, Info.Name);
        Args.push_back(Parsed->first);
        Pos = Parsed->second;
      }
    } else if (Info.ArgTypes.size() != 0) {
      return createStringError(
          "line %zu: callback '%s' expects %zu argument(s), got 0", LineNum + 1,
          Info.Name, Info.ArgTypes.size());
    }

    // Parse the result.
    StringRef ResultPart = Line.substr(EqPos + 3).trim();
    CallbackValue ResultVal;

    if (Info.ResType != VMCallbackValueType::String &&
        Info.ResType != VMCallbackValueType::Array &&
        Info.ResType != VMCallbackValueType::Tuple) {
      auto Result = parseNumericToken(ResultPart, Info.ResType);
      if (!Result)
        return createStringError("line %zu: invalid result for '%s': '%s'",
                                 LineNum + 1, Info.Name,
                                 ResultPart.str().c_str());
      ResultVal = CallbackValue::fromNum(*Result);
    } else if (Info.ResType == VMCallbackValueType::String) {
      auto Result = parseStringLiteral(ResultPart, 0);
      if (!Result || !ResultPart.substr(Result->second).trim().empty())
        return createStringError(
            "line %zu: string result must be double-quoted: '%s'", LineNum + 1,
            ResultPart.str().c_str());
      ResultVal = CallbackValue::fromStr(Result->first);
    } else if (Info.ResType == VMCallbackValueType::Array) {
      auto Result = parseStructuredValue(ResultPart, 0);
      if (!Result || !Result->first.isArray() ||
          !ResultPart.substr(Result->second).trim().empty())
        return createStringError(
            "line %zu: invalid array result for '%s': '%s'", LineNum + 1,
            Info.Name, ResultPart.str().c_str());
      ResultVal = std::move(Result->first);
    } else {
      assert(Info.ResType == VMCallbackValueType::Tuple);
      auto Result = parseStructuredValue(ResultPart, 0);
      if (!Result || !Result->first.isTuple() ||
          !ResultPart.substr(Result->second).trim().empty())
        return createStringError(
            "line %zu: invalid tuple result for '%s': '%s'", LineNum + 1,
            Info.Name, ResultPart.str().c_str());
      ResultVal = std::move(Result->first);
    }

    // Insert into map; error on conflicting duplicates.
    CallbackKey Key{Kind,
                    SmallVector<CallbackValue, 4>(Args.begin(), Args.end())};
    auto [It, Inserted] = Entries.try_emplace(Key, ResultVal);
    if (!Inserted && It->second != ResultVal) {
      std::string PrevStr, CurStr;
      raw_string_ostream PrevOS(PrevStr);
      raw_string_ostream CurOS(CurStr);
      formatValue(PrevOS, It->second);
      formatValue(CurOS, ResultVal);
      return createStringError(
          "line %zu: conflicting result for '%s': previously %s, now %s",
          LineNum + 1, Info.Name, PrevStr.c_str(), CurStr.c_str());
    }
  }

  return Error::success();
}

Error jeandle::loadAndRegisterVMCallbackLog(StringRef FilePath,
                                            StringRef InlineCalleeIRPath) {
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
  ParsedData->InlineCalleeIRPath = InlineCalleeIRPath.str();

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
