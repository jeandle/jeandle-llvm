; RUN: opt -S --jeandle --print-pipeline-passes %s 2>&1 | FileCheck %s --check-prefix=PIPELINE
; RUN: opt -S -passes='java-op-length-folding,loop-simplify,break-crit-edges,loop(loop-rotate,indvars,loop-deletion),loop-unroll<O3;no-partial;no-runtime;no-upperbound;full-unroll-max=128>,instcombine,simplifycfg,partial-escape-iterative' -jeandle-vm-callback-log=%S/partial-escape/Inputs/773_copy_fold_concrete_src.cblog -verify-each %s | FileCheck %s
; RUN: opt -S -passes='java-op-length-folding,loop-simplify,loop(loop-rotate,indvars,loop-deletion),loop-unroll<O3;no-partial;no-runtime;no-upperbound;full-unroll-max=128>,instcombine,simplifycfg,partial-escape-iterative' -jeandle-vm-callback-log=%S/partial-escape/Inputs/773_copy_fold_concrete_src.cblog -verify-each %s | FileCheck %s --check-prefix=UNSPLIT

; An invoke-shaped poll can leave the loop latch ending in an invoke.
; Critical-edge splitting also supports this noncanonical standalone input;
; the production pipeline normalizes nonthrowing polls before loop work.
; PIPELINE: java-op-length-folding
; PIPELINE-SAME: break-crit-edges
; PIPELINE-SAME: loop-rotate
; PIPELINE-SAME: loop-unroll
; PIPELINE-SAME: partial-escape-iterative

target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128-p3:32:32:32"
target triple = "x86_64-unknown-linux-gnu"

declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32, i1, i1)
declare void @jeandle.copy(ptr addrspace(1), i64, ptr addrspace(1), i64, i64, ptr, ptr, i64, i64)
declare hotspotcc void @jeandle.safepoint_poll() noinline
declare i32 @__gxx_personality_v0(...)

define i64 @consume_copy16(ptr addrspace(1) "java-klass"="12345" %src) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %dest = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 12345 to ptr), i32 16, i32 80, i32 16, i32 1048576, i1 false, i1 false)
      to label %copy unwind label %unwind
copy:
  invoke void @jeandle.copy(ptr addrspace(1) %src, i64 0, ptr addrspace(1) %dest, i64 0, i64 16, ptr null, ptr null, i64 16, i64 16) #0
      to label %loop unwind label %unwind
loop:
  %i = phi i32 [ 0, %copy ], [ %next, %body ]
  %sum = phi i64 [ 0, %copy ], [ %added, %body ]
  %done = icmp eq i32 %i, 16
  br i1 %done, label %exit, label %body
body:
  %base = getelementptr inbounds i8, ptr addrspace(1) %dest, i64 16
  %addr = getelementptr inbounds i32, ptr addrspace(1) %base, i32 %i
  %value = load atomic i32, ptr addrspace(1) %addr unordered, align 4
  %wide = sext i32 %value to i64
  %added = add i64 %sum, %wide
  %next = add i32 %i, 1
  invoke hotspotcc void @jeandle.safepoint_poll()
      to label %loop unwind label %unwind
exit:
  ret i64 %sum
unwind:
  %exception = landingpad i64 cleanup
  resume i64 %exception
}

; CHECK-LABEL: define i64 @consume_copy16(
; CHECK-NOT: @jeandle.new_array
; CHECK-NOT: @jeandle.copy
; CHECK-NOT: phi
; CHECK: load atomic i32
; CHECK: {{call|invoke}} hotspotcc void @jeandle.safepoint_poll()
; CHECK: ret i64
; UNSPLIT-LABEL: define i64 @consume_copy16(
; UNSPLIT: {{call|invoke}} hotspotcc ptr addrspace(1) @jeandle.new_array
; UNSPLIT: phi
; UNSPLIT: {{call|invoke}} hotspotcc void @jeandle.safepoint_poll()

define i64 @consume_copy64(ptr addrspace(1) "java-klass"="12345" %src) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %dest = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 12345 to ptr), i32 64, i32 272, i32 16, i32 1048576, i1 false, i1 false)
      to label %copy unwind label %unwind
copy:
  invoke void @jeandle.copy(ptr addrspace(1) %src, i64 0, ptr addrspace(1) %dest, i64 0, i64 64, ptr null, ptr null, i64 64, i64 64) #0
      to label %loop unwind label %unwind
loop:
  %i = phi i32 [ 0, %copy ], [ %next, %body ]
  %sum = phi i64 [ 0, %copy ], [ %added, %body ]
  %done = icmp eq i32 %i, 64
  br i1 %done, label %exit, label %body
body:
  %base = getelementptr inbounds i8, ptr addrspace(1) %dest, i64 16
  %addr = getelementptr inbounds i32, ptr addrspace(1) %base, i32 %i
  %value = load atomic i32, ptr addrspace(1) %addr unordered, align 4
  %wide = sext i32 %value to i64
  %added = add i64 %sum, %wide
  %next = add i32 %i, 1
  invoke hotspotcc void @jeandle.safepoint_poll()
      to label %loop unwind label %unwind
exit:
  ret i64 %sum
unwind:
  %exception = landingpad i64 cleanup
  resume i64 %exception
}

; CHECK-LABEL: define i64 @consume_copy64(
; CHECK-NOT: @jeandle.new_array
; CHECK-NOT: @jeandle.copy
; CHECK-NOT: phi
; CHECK: load atomic i32
; CHECK: {{call|invoke}} hotspotcc void @jeandle.safepoint_poll()
; CHECK: ret i64
; UNSPLIT-LABEL: define i64 @consume_copy64(
; UNSPLIT: {{call|invoke}} hotspotcc ptr addrspace(1) @jeandle.new_array
; UNSPLIT: phi
; UNSPLIT: {{call|invoke}} hotspotcc void @jeandle.safepoint_poll()

attributes #0 = { "jeandle.copy.kind"="arraycopy" "jeandle.copy.validated" }
!java-method-compilation = !{}
