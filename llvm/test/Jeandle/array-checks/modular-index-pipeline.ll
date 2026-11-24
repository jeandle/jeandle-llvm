; RUN: opt -jeandle-vm-callback-log=%S/../Inputs/pre-pea-high-tier-e2e.cblog -passes='jeandle<O3>' -print-after=indvars -print-loop-func-scope -filter-print-funcs=scaled -disable-output %s 2>&1 | FileCheck %s
; RUN: opt -jeandle-vm-callback-log=%S/../Inputs/pre-pea-high-tier-e2e.cblog -passes='jeandle<O3>' -jeandle-pea-iterations=0 -print-after=indvars -print-loop-func-scope -filter-print-funcs=scaled -disable-output %s 2>&1 | FileCheck %s

; The early canonicalization still proves no-wrap on the controller. Keep
; modular Java index math narrow through check elimination. The final loop
; preparation can widen and common casts before expanding the poll.
; CHECK: IR Dump After IndVarSimplifyPass
; CHECK: define {{.*}}@scaled(
; CHECK: mul {{(nuw )?(nsw )?}}i32
; CHECK: add nuw nsw i32
; CHECK: IR Dump After

target datalayout = "e-p:64:64-i64:64-n32:64"
@llvm.used = appending global [2 x ptr] [ptr @jeandle.pre_barrier, ptr @jeandle.post_barrier], section "llvm.metadata"
define private hotspotcc void @jeandle.pre_barrier(ptr addrspace(1) %addr) #0 { ret void }
define private hotspotcc void @jeandle.post_barrier(ptr addrspace(1) %addr, ptr addrspace(1) %oop) #0 { ret void }
attributes #0 = { noinline "lower-phase"="1" }

define i32 @scaled(ptr %a, i32 noundef range(i32 0, -2147483648) %length, i32 noundef %end, i32 noundef %offset) {
entry:
  %enter = icmp sgt i32 %end, 0
  br i1 %enter, label %loop, label %exit
loop:
  %i = phi i32 [ 0, %entry ], [ %next, %body ]
  %sum = phi i32 [ 0, %entry ], [ %added, %body ]
  %scaled = mul i32 %i, 3
  %index = add i32 %scaled, %offset
  %ok = icmp ult i32 %index, %length
  br i1 %ok, label %body, label %fail
body:
  %wide = sext i32 %index to i64
  %address = getelementptr i32, ptr %a, i64 %wide
  %value = load atomic i32, ptr %address unordered, align 4
  %added = add i32 %sum, %value
  %next = add i32 %i, 1
  %more = icmp slt i32 %next, %end
  br i1 %more, label %loop, label %exit
fail:
  ret i32 -1
exit:
  %result = phi i32 [ 0, %entry ], [ %added, %body ]
  ret i32 %result
}
!java-method-compilation = !{}
