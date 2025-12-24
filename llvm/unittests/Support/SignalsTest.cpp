//===-- llvm/unittest/Support/SignalsTest.cpp - Signals unit tests --------===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//
///
/// \file
/// This file contains unit tests for Signals.cpp and Signals.inc.
///
//===----------------------------------------------------------------------===//

#include "llvm/Support/Signals.h"
#include "llvm/ADT/ScopeExit.h"
#include "llvm/Config/config.h"
#include "llvm/Support/FileSystem.h"
#include "gmock/gmock.h"
#include "gtest/gtest.h"

using namespace llvm;
using namespace llvm::sys;
using testing::MatchesRegex;
using testing::Not;

#define TAG_BEGIN "\\{\\{\\{"
#define TAG_END "\\}\\}\\}"
// %p in the Symbolizer Markup Format spec
#define P_REGEX "(0+|0x[0-9a-fA-F]+)"
// %i in the Symbolizer Markup Format spec
#define I_REGEX "(0x[0-9a-fA-F]+|0[0-7]+|[0-9]+)"

#if defined(HAVE_BACKTRACE) && ENABLE_BACKTRACES &&                            \
    (defined(__linux__) || defined(__FreeBSD__) ||                             \
     defined(__FreeBSD_kernel__) || defined(__NetBSD__))
TEST(SignalsTest, PrintsSymbolizerMarkup) {
  auto Exit =
      make_scope_exit([]() { unsetenv("LLVM_ENABLE_SYMBOLIZER_MARKUP"); });
  setenv("LLVM_ENABLE_SYMBOLIZER_MARKUP", "1", 1);
  std::string Res;
  raw_string_ostream RawStream(Res);
  PrintStackTrace(RawStream);
  EXPECT_THAT(Res, MatchesRegex(TAG_BEGIN "reset" TAG_END ".*"));
  // Module line for main binary
  EXPECT_THAT(Res,
              MatchesRegex(".*" TAG_BEGIN
                           "module:0:[^:]*SupportTests:elf:[0-9a-f]+" TAG_END
                           ".*"));
  // Text segment for main binary
  EXPECT_THAT(Res, MatchesRegex(".*" TAG_BEGIN "mmap:" P_REGEX ":" I_REGEX
                                ":load:0:rx:" P_REGEX TAG_END ".*"));
  // Backtrace line
  EXPECT_THAT(Res, MatchesRegex(".*" TAG_BEGIN "bt:0:" P_REGEX ".*"));
}

TEST(SignalsTest, SymbolizerMarkupDisabled) {
  auto Exit = make_scope_exit([]() { unsetenv("LLVM_DISABLE_SYMBOLIZATION"); });
  setenv("LLVM_DISABLE_SYMBOLIZATION", "1", 1);
  std::string Res;
  raw_string_ostream RawStream(Res);
  PrintStackTrace(RawStream);
  EXPECT_THAT(Res, Not(MatchesRegex(TAG_BEGIN "reset" TAG_END ".*")));
}

#endif // defined(HAVE_BACKTRACE) && ...

TEST(SignalsTest, GeneratesHsErrLog) {
#if defined(GTEST_HAS_DEATH_TEST) && defined(LLVM_ON_UNIX)
  // Determine a unique file name for the log test
  SmallString<128> TestFile;
  int FD;
  std::error_code EC =
      sys::fs::createTemporaryFile("hs_err_test", "log", FD, TestFile);
  ASSERT_FALSE(EC);
  sys::fs::remove(TestFile); // verify creation by the signal handler

  // We need to set the environment variable for the child process.
  // ASSERT_DEATH runs in a child, but we can't easily pass env vars solely to
  // it without setting in parent (which might affect others). However, GTest
  // runs sequentially usually.

  setenv("LLVM_HS_ERR_FILE", TestFile.c_str(), 1);
  auto Exit = make_scope_exit([]() { unsetenv("LLVM_HS_ERR_FILE"); });

  ASSERT_DEATH(
      {
        sys::PrintStackTraceOnErrorSignal("SignalsTest");
        abort();
      },
      "");
  bool Exists = sys::fs::exists(TestFile);
  EXPECT_TRUE(Exists);

  if (Exists) {
    sys::fs::remove(TestFile);
  }
#endif
}
