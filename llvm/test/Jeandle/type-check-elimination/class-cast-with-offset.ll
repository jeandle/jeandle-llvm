; Copyright (c) 2026, the Jeandle-LLVM Authors. All Rights Reserved.
;
; Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM Exceptions.
; See https://llvm.org/LICENSE.txt for license information.
; SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
;
; RUN: opt -S -passes="type-check-elimination" -jeandle-vm-callback-log=%S/Inputs/checkcast-dissolved.cblog %s 2>&1 | FileCheck %s

; A phase-0 checkcast after SimplifyCFG dissolution: %pass has two
; predecessors — the null edge from %site (no non-null type constraint,
; skipped) and the check edge from %check_subtype proving klass 22 — and no
; edge dominates %pass. The query in %pass folds via the union of the
; non-null incoming edges.

declare i1 @jeandle.checkcast_nonnull_with_offset(ptr addrspace(0), ptr addrspace(1) nonnull, i32)

define i1 @test(ptr addrspace(1) %obj) gc "hotspotgc" {
site:
  %is_null = icmp eq ptr addrspace(1) %obj, null
  br i1 %is_null, label %pass, label %check_subtype

check_subtype:
  %is_sub = call i1 @jeandle.checkcast_nonnull_with_offset(ptr addrspace(0) inttoptr (i64 22 to ptr addrspace(0)), ptr addrspace(1) nonnull %obj, i32 32)
  br i1 %is_sub, label %pass, label %fail

pass:
  %r = call i1 @jeandle.checkcast_nonnull_with_offset(ptr addrspace(0) inttoptr (i64 22 to ptr addrspace(0)), ptr addrspace(1) nonnull %obj, i32 32)
  ret i1 %r

fail:
  ret i1 false
}

; The check in %check_subtype is preserved (its own site proves nothing); the
; query in %pass folds.
; CHECK: check_subtype:
; CHECK-NEXT:   %is_sub = call i1 @jeandle.checkcast_nonnull_with_offset
; CHECK: pass:
; CHECK-NEXT:   ret i1 true

!java-method-compilation = !{}
