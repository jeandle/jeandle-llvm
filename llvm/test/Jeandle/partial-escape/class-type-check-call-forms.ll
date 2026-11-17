; Copyright (c) 2026, the Jeandle-LLVM Authors. All Rights Reserved.
;
; Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM Exceptions.
; See https://llvm.org/LICENSE.txt for license information.
; SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
;
; RUN: opt -S -verify-each -passes="require<partial-escape-analysis>,partial-escape-transform" -jeandle-vm-callback-log=%S/Inputs/10_checkcast_folded_true.cblog %s | FileCheck %s

; A known subtype relation does not permit folding unsupported helper calls.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare hotspotcc i1 @jeandle.check_instanceof(ptr, ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

; CHECK-LABEL: define i1 @wrong_cc(
; CHECK: %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK: %r = call i1 @jeandle.check_instanceof
; CHECK-NEXT: ret i1 %r
define i1 @wrong_cc() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 5 to ptr), i32 16, i1 false)
      to label %normal unwind label %unwind
normal:
  %r = call i1 @jeandle.check_instanceof(ptr inttoptr (i64 4 to ptr), ptr addrspace(1) %o)
  ret i1 %r
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define i1 @bundled_check(
; CHECK: %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK: %r = call hotspotcc i1 @jeandle.check_instanceof{{.*}}[ "deopt"(i32 0) ]
; CHECK-NEXT: ret i1 %r
define i1 @bundled_check() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 5 to ptr), i32 16, i1 false)
      to label %normal unwind label %unwind
normal:
  %r = call hotspotcc i1 @jeandle.check_instanceof(ptr inttoptr (i64 4 to ptr), ptr addrspace(1) %o) [ "deopt"(i32 0) ]
  ret i1 %r
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define hotspotcc i1 @musttail_check(
; CHECK: %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK: %r = musttail call hotspotcc i1 @jeandle.check_instanceof
; CHECK-NEXT: ret i1 %r
define hotspotcc i1 @musttail_check(ptr %unused_klass, ptr addrspace(1) %unused_oop) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 5 to ptr), i32 16, i1 false)
      to label %normal unwind label %unwind
normal:
  %r = musttail call hotspotcc i1 @jeandle.check_instanceof(ptr inttoptr (i64 4 to ptr), ptr addrspace(1) %o)
  ret i1 %r
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

!java-method-compilation = !{}
