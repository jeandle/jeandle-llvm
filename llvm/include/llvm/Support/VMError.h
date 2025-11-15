//===- llvm/Support/VMError.h - VM Error Logging ----------------*- C++ -*-===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//
//
// This file provides assert failure interception to generate hs_err logs.
// The actual interception is done by overriding platform-specific assert
// failure functions (__assert_fail on Linux, __assert_rtn on macOS,
// _wassert on Windows) in VMError.cpp.
//
// Simply linking VMError.cpp will enable hs_err log generation for all
// assert() failures throughout the codebase.
//
//===----------------------------------------------------------------------===//

#ifndef LLVM_SUPPORT_VMERROR_H
#define LLVM_SUPPORT_VMERROR_H

// This header exists primarily for documentation purposes.
// The actual functionality is provided by the override functions in VMError.cpp
// which are automatically linked when building with LLVMSupport.

#endif // LLVM_SUPPORT_VMERROR_H
