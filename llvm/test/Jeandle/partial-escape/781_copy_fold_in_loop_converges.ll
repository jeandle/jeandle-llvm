; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" -jeandle-vm-callback-log=%S/Inputs/781_copy_fold_in_loop_converges.cblog %s | FileCheck %s
; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" -jeandle-vm-callback-log=%S/Inputs/781_copy_fold_in_loop_converges.cblog -jeandle-pea-loop-fixpoint-max-iters=2 %s | FileCheck %s

; A concrete-source copy INSIDE a loop body. The loop fixpoint re-processes
; the copy every iteration; the element loads must be reused from
; CopyElementLoadCache (same Value* across iterations) so the B/B' field
; state converges instead of escalating to MaterializeAll. The copy and the
; allocation are eliminated; exactly one pair of element loads is placed at
; the call site, and the in-loop destination load folds to the cached load.
; The second RUN stresses convergence with a tightened iteration cap.

declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32, i1, i1)
declare void @jeandle.copy(ptr addrspace(1), i64, ptr addrspace(1), i64, i64, ptr, ptr, i64, i64)
declare i32 @__gxx_personality_v0(...)

define i32 @copy_fold_in_loop(ptr addrspace(1) "java-klass"="12345" %src) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %dest = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
            ptr inttoptr (i64 12345 to ptr), i32 2, i32 24, i32 16, i32 1048576, i1 false, i1 false)
         to label %head unwind label %u
head:
  br label %loop
loop:
  %i = phi i32 [ 0, %head ], [ %inext, %body ]
  invoke void @jeandle.copy(ptr addrspace(1) %src, i64 0, ptr addrspace(1) %dest, i64 0, i64 2,
                            ptr null, ptr null, i64 2, i64 2)
      #0 [ "deopt"(i32 99, i32 99, i64 12, ptr addrspace(1) null) ]
      to label %body unwind label %u
body:
  %db = getelementptr inbounds i8, ptr addrspace(1) %dest, i32 16
  %d0 = getelementptr inbounds i32, ptr addrspace(1) %db, i64 0
  %d1 = getelementptr inbounds i32, ptr addrspace(1) %db, i64 1
  %v0 = load atomic i32, ptr addrspace(1) %d0 unordered, align 4
  %v1 = load atomic i32, ptr addrspace(1) %d1 unordered, align 4
  %sum = add i32 %v0, %v1
  %inext = add i32 %i, 1
  %cond = icmp slt i32 %inext, 2
  br i1 %cond, label %loop, label %exit
exit:
  ret i32 %sum
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

attributes #0 = { "jeandle.copy.kind"="arraycopy" "jeandle.copy.validated" }

; CHECK-LABEL: define i32 @copy_fold_in_loop
; CHECK-NOT: jeandle.new_array
; CHECK-NOT: jeandle.copy
; CHECK: %[[A0:.*]] = getelementptr inbounds i8, ptr addrspace(1) %src, i64 16
; CHECK: %[[L0:.*]] = load atomic i32, ptr addrspace(1) %[[A0]] unordered, align 4
; CHECK: %[[A1:.*]] = getelementptr inbounds i8, ptr addrspace(1) %src, i64 20
; CHECK: %[[L1:.*]] = load atomic i32, ptr addrspace(1) %[[A1]] unordered, align 4
; The destination loads fold to the cached element loads; the sum consumer
; keeps both element loads live.
; CHECK: %sum = add i32 %[[L0]], %[[L1]]
; CHECK: ret i32 %sum

!java-method-compilation = !{}
