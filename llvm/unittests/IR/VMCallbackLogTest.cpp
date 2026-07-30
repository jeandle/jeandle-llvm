//===- unittests/IR/VMCallbackLogTest.cpp - VM callback value tests -------===//
//
// Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM
// Exceptions. See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#include "llvm/IR/Jeandle/VMCallbackLog.h"
#include "llvm/ADT/SmallString.h"
#include "llvm/Support/FileSystem.h"
#include "llvm/Support/MemoryBuffer.h"
#include "llvm/Support/raw_ostream.h"
#include "gtest/gtest.h"

#include <cstdint>
#include <string>
#include <tuple>
#include <vector>

using namespace llvm;
using namespace llvm::jeandle;

TEST(VMCallbackValueTest, NestedTupleAndArrayRoundTrip) {
  using Element = std::tuple<int64_t, std::string>;
  using Value = std::tuple<int, std::string, std::vector<Element>>;

  const Value Input{7, "root", {{1, "one"}, {2, "two"}}};
  CallbackValue Encoded = VMCallbackValueCodec<Value>::encode(Input);

  ASSERT_TRUE(Encoded.isTuple());
  ASSERT_EQ(Encoded.tuple().size(), 3U);
  EXPECT_TRUE(Encoded.tuple()[0].isNumber());
  EXPECT_TRUE(Encoded.tuple()[1].isString());
  ASSERT_TRUE(Encoded.tuple()[2].isArray());
  ASSERT_EQ(Encoded.tuple()[2].array().size(), 2U);
  EXPECT_TRUE(Encoded.tuple()[2].array()[0].isTuple());

  EXPECT_EQ(VMCallbackValueCodec<Value>::decode(Encoded), Input);
}

TEST(VMCallbackValueTest, ArrayAndTupleHaveDistinctKinds) {
  const CallbackValue Number = CallbackValue::fromNum(1);
  const CallbackValue Array = CallbackValue::fromArray({Number});
  const CallbackValue Tuple = CallbackValue::fromTuple({Number});

  EXPECT_NE(Array, Tuple);
  EXPECT_LT(Array, Tuple);
}

TEST(VMCallbackValueTest, EscapesStringsInTextLog) {
  SmallString<128> Path;
  int FD;
  ASSERT_FALSE(
      sys::fs::createTemporaryFile("vm-callback-log", "cblog", FD, Path));
  raw_fd_ostream(FD, true).close();

  const std::string Input = "quote\" slash\\ line\n tab\t control\x01";
  {
    VMCallbackLogRecorder Recorder;
    Recorder.recordIfNew(CK_GetOopHandleName, {CallbackValue::fromNum(7)},
                         CallbackValue::fromStr(Input));
    if (Error E = Recorder.dump(Path))
      FAIL() << toString(std::move(E));
  }

  auto BufferOrErr = MemoryBuffer::getFile(Path);
  ASSERT_TRUE(static_cast<bool>(BufferOrErr));
  EXPECT_EQ(BufferOrErr.get()->getBuffer(),
            "GetOopHandleName 7 = \"quote\\\" slash\\\\ line\\n tab\\t "
            "control\\x01\"\n");
  EXPECT_FALSE(sys::fs::remove(Path));
}
