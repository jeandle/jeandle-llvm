; Copyright (c) 2026, the Jeandle-LLVM Authors. All Rights Reserved.
;
; Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM Exceptions.
; See https://llvm.org/LICENSE.txt for license information.
; SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
;
; RUN: %python %S/Inputs/class-query-dag.py > %t.ll
; RUN: opt -S -passes=constant-field-folding -jeandle-vm-callback-log=%S/Inputs/class-query-dag.cblog %t.ll | FileCheck %s
;
; A small shared DAG used to expand into exponentially many recursive visits.
; Unknown results must also terminate promptly. Wide PHIs and deep chains must
; stay dynamic when the per-query visit/depth limit is exhausted.
;
; CHECK-LABEL: define i32 @shared_dag(
; CHECK-NOT: call i32 @jeandle.class_is_primitive
; CHECK: ret i32 0
;
; CHECK-LABEL: define i32 @unknown_dag(
; CHECK: %query = call i32 @jeandle.class_is_primitive
; CHECK: ret i32 %query
;
; CHECK-LABEL: define i32 @mixed_mirrors(
; CHECK: %query = call i32 @jeandle.class_is_primitive
;
; CHECK-LABEL: define i32 @deep_dag(
; CHECK: %query = call i32 @jeandle.class_is_primitive
;
; CHECK-LABEL: define i32 @wide_phi(
; CHECK: %query = call i32 @jeandle.class_is_primitive
;
; CHECK-LABEL: define i32 @cyclic_mirrors(
; CHECK: %query = call i32 @jeandle.class_is_primitive

; CHECK-LABEL: define i1 @equality_shared_left(
; CHECK-NOT: icmp eq
; CHECK: ret i1 false

; CHECK-LABEL: define i1 @equality_shared_right(
; CHECK-NOT: icmp eq
; CHECK: ret i1 false

; CHECK-LABEL: define i1 @equality_unknown(
; CHECK: %cmp = icmp eq
; CHECK: ret i1 %cmp

; CHECK-LABEL: define i1 @equality_deep(
; CHECK: %cmp = icmp eq
; CHECK: ret i1 %cmp

; CHECK-LABEL: define i1 @equality_operand_pairs(
; CHECK: %cmp = icmp eq
; CHECK: ret i1 %cmp

; CHECK-LABEL: define i1 @equality_cycle(
; CHECK: %cmp = icmp eq
; CHECK: ret i1 %cmp

; CHECK-LABEL: define i1 @equality_wide(
; CHECK: %cmp = icmp eq
; CHECK: ret i1 %cmp
