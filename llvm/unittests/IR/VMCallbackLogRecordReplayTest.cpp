//===- VMCallbackLogRecordReplayTest.cpp - VM callback log E2E test -------===//
//
// Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM
// Exceptions. See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#include "llvm/ADT/SmallString.h"
#include "llvm/IR/Jeandle/VMCallbackLog.h"
#include "llvm/Support/FileSystem.h"
#include "llvm/Support/MemoryBuffer.h"
#include "llvm/Support/raw_ostream.h"
#include "gtest/gtest.h"

using namespace llvm;
using namespace llvm::jeandle;

static ConstantFieldResult fakeGetConstantField(int OopId, int Offset) {
  EXPECT_EQ(OopId, 7);
  EXPECT_EQ(Offset, 16);
  return {10, 42};
}

static CloneInstanceInfoResult
fakeGetCloneInstanceInfo(uintptr_t, bool, CloneInstanceInfoPurpose Purpose) {
  if (Purpose == CloneInstanceInfoPurpose::FieldState)
    return {4, 2, {{12, 4}, {16, 8}}};
  return {3, 2, {}};
}

TEST(VMCallbackLogRecordReplayTest, RecordsAndReplaysTupleResult) {
  SmallString<128> Path;
  int FD;
  ASSERT_FALSE(sys::fs::createTemporaryFile("vm-callback-record-replay",
                                            "cblog", FD, Path));
  raw_fd_ostream(FD, true).close();

  VMCallbacks Callbacks{};
  Callbacks.GetConstantField = &fakeGetConstantField;
  Callbacks.GetCloneInstanceInfo = &fakeGetCloneInstanceInfo;
  registerVMCallbacks(Callbacks);
  enableVMCallbackRecording();

  {
    VMCallbackLogRecorder Recorder;
    const auto *RecordingCallbacks = getVMCallbacks();
    ASSERT_NE(RecordingCallbacks, nullptr);
    EXPECT_EQ(RecordingCallbacks->GetConstantField(7, 16),
              (ConstantFieldResult{10, 42}));
    EXPECT_EQ(RecordingCallbacks->GetCloneInstanceInfo(
                  42, true, CloneInstanceInfoPurpose::FieldState),
              (CloneInstanceInfoResult{4, 2, {{12, 4}, {16, 8}}}));
    EXPECT_EQ(RecordingCallbacks->GetCloneInstanceInfo(
                  42, true, CloneInstanceInfoPurpose::ScalarCopy),
              (CloneInstanceInfoResult{3, 2, {}}));
    if (Error E = Recorder.dump(Path))
      FAIL() << toString(std::move(E));
  }

  auto BufferOrErr = MemoryBuffer::getFile(Path);
  ASSERT_TRUE(static_cast<bool>(BufferOrErr));
  EXPECT_EQ(BufferOrErr.get()->getBuffer(),
            "GetConstantField 7 16 = (10, 42)\n"
            "GetCloneInstanceInfo 42 true 0 = (4, 2, [(12, 4), (16, 8)])\n"
            "GetCloneInstanceInfo 42 true 1 = (3, 2, [])\n");

  if (Error E = loadAndRegisterVMCallbackLog(Path, ""))
    FAIL() << toString(std::move(E));
  const auto *ReplayCallbacks = getVMCallbacks();
  ASSERT_NE(ReplayCallbacks, nullptr);
  EXPECT_EQ(ReplayCallbacks->GetConstantField(7, 16),
            (ConstantFieldResult{10, 42}));
  EXPECT_EQ(ReplayCallbacks->GetCloneInstanceInfo(
                42, true, CloneInstanceInfoPurpose::FieldState),
            (CloneInstanceInfoResult{4, 2, {{12, 4}, {16, 8}}}));
  EXPECT_EQ(ReplayCallbacks->GetCloneInstanceInfo(
                42, true, CloneInstanceInfoPurpose::ScalarCopy),
            (CloneInstanceInfoResult{3, 2, {}}));

  EXPECT_FALSE(sys::fs::remove(Path));
}
