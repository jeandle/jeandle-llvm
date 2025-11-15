#include "llvm/Support/FileSystem.h"
#include "llvm/Support/Process.h"
#include "llvm/Support/Signals.h"
#include "llvm/Support/raw_ostream.h"
#include <cstdlib>
#include <iostream>
#include <sstream>

namespace llvm {
namespace vmerror {

static void report_and_die_impl(const char *file, int line, const char *func,
                                const char *expr) {
  int pid = llvm::sys::Process::getProcessId();
  std::stringstream ss;
  ss << "hs_err_pid" << pid << ".log";
  std::string filename = ss.str();

  std::error_code EC;
  llvm::raw_fd_ostream log_file(filename, EC, llvm::sys::fs::OF_None);

  if (!EC) {
    log_file << "#\n";
    log_file << "# A fatal error has been detected by the LLVM Runtime "
                "Environment:\n";
    log_file << "#\n";
    log_file << "# Internal Error (" << file << ":" << line << "), pid=" << pid
             << "\n";
    if (func)
      log_file << "# Function: " << func << "\n";
    log_file << "# assert(" << expr << ") failed\n";
    log_file << "#\n";
    log_file << "# Native frames:\n";

    llvm::sys::PrintStackTrace(log_file);

    log_file.close();

    std::cerr << "#\n";
    std::cerr << "# A fatal error has been detected by the LLVM Runtime "
                 "Environment:\n";
    std::cerr << "#\n";
    std::cerr << "# Internal Error (" << file << ":" << line << "), pid=" << pid
              << "\n";
    std::cerr << "# assert(" << expr << ") failed\n";
    std::cerr << "#\n";
    std::cerr << "# An error report file with more information is saved as:\n";
    std::cerr << "# " << filename << "\n";
    std::cerr << "#\n";
  } else {
    std::cerr << "Failed to create error report file: " << filename << "\n";
    std::cerr << "Error: " << EC.message() << "\n";
    std::cerr << "Assertion failed: " << expr << ", file " << file << ", line "
              << line << "\n";
    llvm::sys::PrintStackTrace(llvm::errs());
  }

  abort();
}

} // namespace vmerror
} // namespace llvm

// Linux/glibc: override __assert_fail to intercept all assert() calls
extern "C" void __assert_fail(const char *assertion, const char *file,
                              unsigned int line, const char *function) {
  llvm::vmerror::report_and_die_impl(file, static_cast<int>(line), function,
                                     assertion);
}
