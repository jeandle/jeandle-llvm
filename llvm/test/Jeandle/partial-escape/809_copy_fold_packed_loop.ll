; RUN: opt -S -verify-each -passes="require<partial-escape-analysis>,partial-escape-transform" -jeandle-vm-callback-log=%S/Inputs/807_copy_fold_packed_groups.cblog %s | FileCheck %s
; RUN: opt -S -verify-each -passes="require<partial-escape-analysis>,partial-escape-transform" -jeandle-pea-loop-fixpoint-max-iters=2 -jeandle-vm-callback-log=%S/Inputs/807_copy_fold_packed_groups.cblog %s | FileCheck %s
; RUN: opt -disable-output -verify-each -passes="require<partial-escape-analysis>,partial-escape-transform" -jeandle-pea-loop-fixpoint-max-iters=1 -jeandle-vm-callback-log=%S/Inputs/807_copy_fold_packed_groups.cblog %s

; Active groups survive loop merges and retries. A forced overflow must replay
; the current group without retaining speculative field or copy effects.
target datalayout = "e-p:64:64"
declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32, i1, i1)
declare void @jeandle.copy(ptr addrspace(1), i64, ptr addrspace(1), i64, i64, ptr, ptr, i64, i64)
declare i32 @__gxx_personality_v0(...)

; CHECK-LABEL: define i16 @packed_loop(
; CHECK-NOT: @jeandle.new_array
; CHECK-NOT: @jeandle.copy
; CHECK: ret i16 %packed

define i16 @packed_loop(i16 %input) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %src = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 12345 to ptr), i32 2, i32 24, i32 16, i32 1048576, i1 false, i1 false) to label %alloc unwind label %u
alloc:
  %dst = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 12345 to ptr), i32 2, i32 24, i32 16, i32 1048576, i1 false, i1 false) to label %head unwind label %u
head:
  %d0 = getelementptr inbounds i8, ptr addrspace(1) %dst, i64 16
  %d1 = getelementptr inbounds i8, ptr addrspace(1) %dst, i64 17
  store atomic i8 0, ptr addrspace(1) %d0 unordered, align 1
  store atomic i8 0, ptr addrspace(1) %d1 unordered, align 1
  br label %loop
loop:
  %i = phi i32 [0, %head], [%inext, %body]
  %packed = phi i16 [%input, %head], [%next, %body]
  %sp = getelementptr inbounds i8, ptr addrspace(1) %src, i64 16
  store atomic i16 %packed, ptr addrspace(1) %sp unordered, align 1
  invoke void @jeandle.copy(ptr addrspace(1) %src, i64 0, ptr addrspace(1) %dst, i64 0, i64 2, ptr null, ptr null, i64 2, i64 2) #0 to label %body unwind label %u
body:
  %v = load atomic i16, ptr addrspace(1) %d0 unordered, align 1
  %inext = add i32 %i, 1
  %next = add i16 %packed, 257
  %more = icmp slt i32 %inext, 4
  br i1 %more, label %loop, label %exit
exit:
  ret i16 %v
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}
attributes #0 = { "jeandle.copy.kind"="arraycopy" "jeandle.copy.validated" }
!java-method-compilation = !{}
