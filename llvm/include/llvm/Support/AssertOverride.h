//===- llvm/Support/AssertOverride.h - Assert redirection -------*- C++ -*-===//
//
// Copyright (c) 2025, the Jeandle-LLVM Authors. All Rights Reserved.
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//
//
// This header optionally redirects assert() failures to
// llvm::report_fatal_error(). It is intended to be force-included for LLVM
// builds when LLVM_ASSERTS_REPORT_FATAL_ERROR is enabled.
//
//===----------------------------------------------------------------------===//

#ifndef LLVM_SUPPORT_ASSERTOVERRIDE_H
#define LLVM_SUPPORT_ASSERTOVERRIDE_H

#include <assert.h>

#ifdef __cplusplus
#include "llvm/Support/ErrorHandling.h"
#include <stdio.h>
#if !defined(NDEBUG) && defined(LLVM_ASSERTS_REPORT_FATAL_ERROR) &&            \
    defined(LLVM_BUILDING_LLVM)
namespace llvm {
namespace detail {
[[noreturn]] inline void
report_assertion_failure(const char *Expr, const char *File, unsigned Line) {
  char Buffer[512];
  int Result = ::snprintf(Buffer, sizeof(Buffer),
                          "Assertion failed: %s at %s:%u", Expr, File, Line);
  const char *Message = (Result >= 0) ? Buffer : "Assertion failed";
  ::llvm::report_fatal_error(Message, true);
}
} // namespace detail
} // namespace llvm

#define llvm_assert(expr)                                                      \
  do {                                                                         \
    if (!(expr))                                                               \
      ::llvm::detail::report_assertion_failure(#expr, __FILE__, __LINE__);     \
  } while (false)
#undef assert
#define assert(expr) llvm_assert(expr)

#if defined(__GLIBC__)
// glibc assert uses __assert_fail or __assert_fail_base; redirect both.
#undef __assert_fail
#define __assert_fail(expr, file, line, func)                                  \
  ::llvm::detail::report_assertion_failure(expr, file, line)
#undef __assert_fail_base
#define __assert_fail_base(fmt, expr, file, line, func)                        \
  ::llvm::detail::report_assertion_failure(expr, file, line)
#endif // __GLIBC__
#else
#define llvm_assert(expr) assert(expr)
#endif // !NDEBUG && LLVM_ASSERTS_REPORT_FATAL_ERROR && LLVM_BUILDING_LLVM
#endif // __cplusplus

#endif // LLVM_SUPPORT_ASSERTOVERRIDE_H
