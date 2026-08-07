; RUN: opt -passes='function(early-cse,instcombine,loop-simplify,lcssa,safepoint-poll-elimination<early>,safepoint-strip-mining<strip-mining>,safepoint-poll-elimination<after-strip-mining>)' \
; RUN:   -jeandle-loop-strip-mining-iter=1000 -S < %s \
; RUN:   | FileCheck %s --check-prefix=PRECANON
; RUN: opt -passes='function(early-cse,instcombine,loop-simplify,lcssa,safepoint-poll-elimination<early>,loop-mssa(loop-rotate,licm),safepoint-strip-mining<strip-mining>,safepoint-poll-elimination<after-strip-mining>,verify<jeandle-safepoint-coverage>)' \
; RUN:   -jeandle-loop-strip-mining-iter=1000 \
; RUN:   -jeandle-verify-safepoint-coverage=fatal -S < %s \
; RUN:   | FileCheck %s --check-prefix=CANON
; RUN: opt -verify-each \
; RUN:   -passes='function(early-cse,instcombine,loop-simplify,lcssa,safepoint-poll-elimination<early>,loop-mssa(loop-rotate,licm),safepoint-strip-mining<strip-mining>,safepoint-poll-elimination<after-strip-mining>,verify<jeandle-safepoint-coverage>)' \
; RUN:   -jeandle-loop-strip-mining-iter=1000 \
; RUN:   -jeandle-verify-safepoint-coverage=fatal -disable-output < %s
; RUN: opt -passes='function(early-cse,instcombine,loop-simplify,lcssa,safepoint-poll-elimination<early>,loop-mssa(loop-rotate,licm,simple-loop-unswitch<trivial>,licm,simple-loop-unswitch<nontrivial;trivial>),guard-widening,loop-mssa(licm),loop-mssa(loop-predication,licm,simple-loop-unswitch<nontrivial;trivial>,guard-widening),lower-widenable-condition,lower-guard-intrinsic,simplifycfg,irce,instcombine,simplifycfg,loop-simplify,lcssa,loop-mssa(loop-rotate,licm),safepoint-strip-mining<strip-mining>,safepoint-poll-elimination<after-strip-mining>,verify<jeandle-safepoint-coverage>)' \
; RUN:   -jeandle-loop-strip-mining-iter=1000 \
; RUN:   -jeandle-verify-safepoint-coverage=fatal -S < %s \
; RUN:   | FileCheck %s --check-prefix=PIPELINE

; This is minimized from the frontend IR for:
;   for (int i = 0; i < a.length; i++) c[i] = a[i] + b[i];
; The loop header performs the null guard, while the mandatory array.length
; test lives in the dominated success block. Loop rotation and LICM must make
; that test canonical without making a runtime-skippable test look mandatory.

target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i8:8:32-i64:64-i128:128-n32:64-S128-Fn32-p3:32:32:32"
target triple = "aarch64-unknown-linux-gnu"

declare hotspotcc void @jeandle.safepoint_poll()

define void @direct_array_length(ptr addrspace(1) %a,
                                 ptr addrspace(1) noalias %b,
                                 ptr addrspace(1) noalias %c) "java-method" {
entry:
  br label %loop.header

loop.header:
  %iv = phi i32 [ 0, %entry ], [ %iv.next, %loop.latch ]
  %is.null = icmp eq ptr addrspace(1) %a, null
  br i1 %is.null, label %null.exit, label %array.length.test

array.length.test:
  %length.addr = getelementptr inbounds i8, ptr addrspace(1) %a, i64 12
  %length = load atomic i32, ptr addrspace(1) %length.addr unordered, align 4,
      !range !0, !invariant.load !1, !noundef !1
  %continue = icmp slt i32 %iv, %length
  br i1 %continue, label %loop.body, label %loop.exit

loop.body:
  %index = sext i32 %iv to i64
  %a.base = getelementptr inbounds i8, ptr addrspace(1) %a, i64 16
  %a.elem = getelementptr inbounds i32, ptr addrspace(1) %a.base, i64 %index
  %a.value = load atomic i32, ptr addrspace(1) %a.elem unordered, align 4
  %b.base = getelementptr inbounds i8, ptr addrspace(1) %b, i64 16
  %b.elem = getelementptr inbounds i32, ptr addrspace(1) %b.base, i64 %index
  %b.value = load atomic i32, ptr addrspace(1) %b.elem unordered, align 4
  %sum = add i32 %a.value, %b.value
  %c.base = getelementptr inbounds i8, ptr addrspace(1) %c, i64 16
  %c.elem = getelementptr inbounds i32, ptr addrspace(1) %c.base, i64 %index
  store atomic i32 %sum, ptr addrspace(1) %c.elem unordered, align 4
  %iv.next = add i32 %iv, 1
  call hotspotcc void @jeandle.safepoint_poll()
      [ "deopt"(ptr addrspace(1) %a, ptr addrspace(1) %b,
                  ptr addrspace(1) %c, i32 %iv.next) ]
  br label %loop.latch

loop.latch:
  br label %loop.header

null.exit:
  ret void

loop.exit:
  ret void
}

; PRECANON-LABEL: define void @direct_array_length(
; PRECANON-NOT: .outer
; PRECANON: call hotspotcc void @jeandle.safepoint_poll()

; CANON-LABEL: define void @direct_array_length(
; CANON-NOT: .outer
; CANON: call hotspotcc void @jeandle.safepoint_poll()

define void @runtime_skippable_array_length(ptr addrspace(1) %a,
                                            i1 %test.length) "java-method" {
entry:
  br label %loop.header

loop.header:
  %iv = phi i32 [ 0, %entry ], [ %iv.next, %loop.latch ]
  %is.null = icmp eq ptr addrspace(1) %a, null
  br i1 %is.null, label %null.exit, label %test.dispatch

test.dispatch:
  br i1 %test.length, label %array.length.test, label %loop.body

array.length.test:
  %length.addr = getelementptr inbounds i8, ptr addrspace(1) %a, i64 12
  %length = load atomic i32, ptr addrspace(1) %length.addr unordered, align 4,
      !range !0, !invariant.load !1, !noundef !1
  %continue = icmp slt i32 %iv, %length
  br i1 %continue, label %loop.body, label %loop.exit

loop.body:
  %iv.next = add i32 %iv, 1
  call hotspotcc void @jeandle.safepoint_poll()
      [ "deopt"(ptr addrspace(1) %a, i32 %iv.next) ]
  br label %loop.latch

loop.latch:
  br label %loop.header

null.exit:
  ret void

loop.exit:
  ret void
}

; PRECANON-LABEL: define void @runtime_skippable_array_length(
; PRECANON-NOT: .outer
; PRECANON: call hotspotcc void @jeandle.safepoint_poll()

; CANON-LABEL: define void @runtime_skippable_array_length(
; CANON-NOT: .outer
; CANON: call hotspotcc void @jeandle.safepoint_poll()

; The loop-varying dispatch cannot be specialized by unswitching. The array
; length test is skipped on alternating iterations, so it must not be used as
; the mandatory counted exit by either the direct or production-shaped run.
define void @varying_skippable_array_length(ptr addrspace(1) %a,
                                            i1 %test.initial) "java-method" {
entry:
  br label %loop.header

loop.header:
  %iv = phi i32 [ 0, %entry ], [ %iv.next, %loop.latch ]
  %test.length = phi i1 [ %test.initial, %entry ], [ %test.next, %loop.latch ]
  %is.null = icmp eq ptr addrspace(1) %a, null
  br i1 %is.null, label %null.exit, label %test.dispatch

test.dispatch:
  br i1 %test.length, label %array.length.test, label %loop.body

array.length.test:
  %length.addr = getelementptr inbounds i8, ptr addrspace(1) %a, i64 12
  %length = load atomic i32, ptr addrspace(1) %length.addr unordered, align 4,
      !range !0, !invariant.load !1, !noundef !1
  %continue = icmp slt i32 %iv, %length
  br i1 %continue, label %loop.body, label %loop.exit

loop.body:
  %iv.next = add i32 %iv, 1
  %test.next = xor i1 %test.length, true
  call hotspotcc void @jeandle.safepoint_poll()
      [ "deopt"(ptr addrspace(1) %a, i32 %iv.next) ]
  br label %loop.latch

loop.latch:
  br label %loop.header

null.exit:
  ret void

loop.exit:
  ret void
}

; PRECANON-LABEL: define void @varying_skippable_array_length(
; PRECANON-NOT: .outer
; PRECANON: call hotspotcc void @jeandle.safepoint_poll()

; CANON-LABEL: define void @varying_skippable_array_length(
; CANON-NOT: .outer
; CANON: call hotspotcc void @jeandle.safepoint_poll()

; PIPELINE-LABEL: define void @direct_array_length(
; PIPELINE: .outer
; PIPELINE: call hotspotcc void @jeandle.safepoint_poll() #{{[0-9]+}}
; PIPELINE-LABEL: define void @runtime_skippable_array_length(
; PIPELINE: call hotspotcc void @jeandle.safepoint_poll()
; PIPELINE-LABEL: define void @varying_skippable_array_length(
; PIPELINE-NOT: .outer
; PIPELINE: call hotspotcc void @jeandle.safepoint_poll()

!java-method-compilation = !{}
!0 = !{i32 0, i32 2147483647}
!1 = !{}

; PIPELINE:     attributes #{{[0-9]+}} = { "jeandle.strip-mined-poll" }
