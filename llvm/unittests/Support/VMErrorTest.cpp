#include "llvm/Support/FileSystem.h"
#include "gtest/gtest.h"
#include <cassert>
#include <cstdio>
#include <fstream>
#include <string>

// Test fixture
class VMErrorTest : public ::testing::Test {};

// Test that assert(false) causes death and creates the log file
TEST_F(VMErrorTest, AssertFailCreatesLog) {
  // We expect the program to die.
  // The error message from assert should be present in stderr.
  // We use a regex to match the expected stderr output, including the log file
  // message.
  const char *ExpectedStderr = "A fatal error has been detected by the LLVM "
                               "Runtime Environment:.*assert.*false.*failed.*"
                               "An error report file with more information is "
                               "saved as:.*hs_err_pid.*\\.log";

  ASSERT_DEATH({ assert(false); }, ExpectedStderr);

  // Verify that the log file was actually created.
  // Since we don't know the PID of the child process created by ASSERT_DEATH,
  // we scan the current directory for a recently created hs_err_pid*.log file.

  std::error_code EC;
  std::string FoundLogFile;
  for (llvm::sys::fs::directory_iterator I(".", EC), E; I != E && !EC;
       I.increment(EC)) {
    std::string Filename = I->path();
    if (Filename.find("hs_err_pid") != std::string::npos &&
        Filename.find(".log") != std::string::npos) {
      // Found a candidate. In a real scenario we might check timestamps,
      // but for this unit test this is likely sufficient.
      FoundLogFile = Filename;
      break;
    }
  }

  ASSERT_FALSE(FoundLogFile.empty())
      << "Could not find generated hs_err log file";

  // Verify content
  std::ifstream LogFile(FoundLogFile);
  std::string Line;
  bool FoundAssertMsg = false;
  while (std::getline(LogFile, Line)) {
    if (Line.find("assert(false) failed") != std::string::npos) {
      FoundAssertMsg = true;
      break;
    }
  }
  LogFile.close();

  EXPECT_TRUE(FoundAssertMsg)
      << "Log file did not contain expected assertion message";

  // Cleanup
  llvm::sys::fs::remove(FoundLogFile);
}
