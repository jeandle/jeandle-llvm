; RUN: opt -S -verify-each -passes="require<partial-escape-analysis>,partial-escape-transform" -jeandle-vm-callback-log=%S/Inputs/813_copy_fold_common_return_replay.cblog %s | FileCheck %s --implicit-check-not="invoke void @jeandle.copy"
; RUN: opt -S -verify-each -passes="require<partial-escape-analysis>,partial-escape-transform,require<partial-escape-analysis>,partial-escape-transform" -jeandle-vm-callback-log=%S/Inputs/813_copy_fold_common_return_replay.cblog %s | FileCheck %s --implicit-check-not="invoke void @jeandle.copy"
; RUN: opt -disable-output -passes="require<partial-escape-analysis>" -jeandle-vm-callback-log=%S/Inputs/813_copy_fold_common_return_replay.cblog -jeandle-dump-pea-stats %s 2>&1 | FileCheck %s --check-prefix=STATS
;
; A shared return also receives null on an allocation's exceptional path.
; Retaining that allocation for escape requires replay on its normal path,
; where the original receiver is available. Purely virtual users can still
; exploit provisional dead edges without materializing at the same PHI shape.
target datalayout = "e-p:64:64"
declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32, i1, i1)
declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @jeandle.copy(ptr addrspace(1), i64, ptr addrspace(1), i64, i64, ptr, ptr, i64, i64)
declare i32 @__gxx_personality_v0(...)

; CHECK-LABEL: define ptr addrspace(1) @common_return_replay(
; STATS: @common_return_replay: NeverEscapes=1 PartiallyEscapes=1 AlwaysEscapes=0 CopyFolds=1
; CHECK-NOT: @jeandle.new_array
; CHECK: %dst = invoke hotspotcc ptr addrspace(1) @jeandle.new_array
; CHECK-NEXT: to label %copy unwind label %unwind
; CHECK: getelementptr inbounds i8, ptr addrspace(1) %dst, i64 17
; CHECK-NEXT: store atomic i8 34, {{.*}} unordered, align 1
; CHECK: getelementptr inbounds i8, ptr addrspace(1) %dst, i64 18
; CHECK-NEXT: store atomic i8 17, {{.*}} unordered, align 1
; CHECK: br label %return
; CHECK: unwind:
; CHECK-NEXT: %ex = landingpad
; CHECK-NOT: store atomic
; CHECK: return:
; CHECK: phi ptr addrspace(1)
; CHECK-SAME: [ %dst, %normal ]
; CHECK-SAME: [ null, %unwind ]
; CHECK-NEXT: ret ptr addrspace(1)
define ptr addrspace(1) @common_return_replay() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %src = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 12345 to ptr), i32 2, i32 24, i32 16, i32 1048576, i1 false, i1 false) to label %alloc unwind label %unwind
alloc:
  %dst = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 12345 to ptr), i32 4, i32 24, i32 16, i32 1048576, i1 false, i1 false) to label %copy unwind label %unwind
copy:
  %sp = getelementptr inbounds i8, ptr addrspace(1) %src, i64 16
  store atomic i16 4386, ptr addrspace(1) %sp unordered, align 2
  invoke void @jeandle.copy(ptr addrspace(1) %src, i64 0, ptr addrspace(1) %dst, i64 1, i64 2, ptr null, ptr null, i64 2, i64 4) #0 to label %normal unwind label %unwind
normal:
  br label %return
unwind:
  %ex = landingpad i64 cleanup
  br label %return
return:
  %result = phi ptr addrspace(1) [ %dst, %normal ], [ null, %unwind ]
  ret ptr addrspace(1) %result
}

; CHECK-LABEL: define i16 @common_merge_stays_virtual(
; STATS: @common_merge_stays_virtual: NeverEscapes=1 PartiallyEscapes=0 AlwaysEscapes=0 CopyFolds=0
; CHECK-NOT: @jeandle.new_array
; CHECK-NOT: store atomic
; CHECK-NOT: load atomic
; CHECK: ret i16 %value
define i16 @common_merge_stays_virtual(i16 %value) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %array = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 12345 to ptr), i32 2, i32 24, i32 16, i32 1048576, i1 false, i1 false) to label %init unwind label %unwind
init:
  %data = getelementptr inbounds i8, ptr addrspace(1) %array, i64 16
  store atomic i16 %value, ptr addrspace(1) %data unordered, align 2
  br label %merge
unwind:
  %ex = landingpad i64 cleanup
  br label %merge
merge:
  %alias = phi ptr addrspace(1) [ %array, %init ], [ null, %unwind ]
  %p = getelementptr inbounds i8, ptr addrspace(1) %alias, i64 16
  %result = load atomic i16, ptr addrspace(1) %p unordered, align 2
  ret i16 %result
}

; A nested receiver can require the same retry while its outer allocation
; already dominates the escape. The retry must propagate without rejecting
; the outer virtualization and thereby reviving the original copy.
; CHECK-LABEL: define ptr addrspace(1) @nested_common_return_replay(
; STATS: @nested_common_return_replay: NeverEscapes=1 PartiallyEscapes=2 AlwaysEscapes=0 CopyFolds=1
; CHECK: %outer = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK-NOT: @jeandle.new_array
; CHECK: %dst = invoke hotspotcc ptr addrspace(1) @jeandle.new_array
; CHECK-NOT: @jeandle.new_array
; CHECK: getelementptr inbounds i8, ptr addrspace(1) %dst, i64 17
; CHECK-NEXT: store atomic i8 34, {{.*}} unordered, align 1
; CHECK: getelementptr inbounds i8, ptr addrspace(1) %dst, i64 18
; CHECK-NEXT: store atomic i8 17, {{.*}} unordered, align 1
; CHECK: return:
; CHECK-NEXT: %[[NESTED:[^ ]+]] = phi ptr addrspace(1) [ null, %unwind ], [ %dst, %normal ]
; CHECK: store atomic ptr addrspace(1) %[[NESTED]],
; CHECK: ret ptr addrspace(1) %outer
define ptr addrspace(1) @nested_common_return_replay() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %outer = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 23456 to ptr), i32 32, i1 false) to label %source unwind label %exit
source:
  %src = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 12345 to ptr), i32 2, i32 24, i32 16, i32 1048576, i1 false, i1 false) to label %alloc unwind label %exit
alloc:
  %dst = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 12345 to ptr), i32 4, i32 24, i32 16, i32 1048576, i1 false, i1 false) to label %copy unwind label %unwind
copy:
  %sp = getelementptr inbounds i8, ptr addrspace(1) %src, i64 16
  store atomic i16 4386, ptr addrspace(1) %sp unordered, align 2
  invoke void @jeandle.copy(ptr addrspace(1) %src, i64 0, ptr addrspace(1) %dst, i64 1, i64 2, ptr null, ptr null, i64 2, i64 4) #0 to label %normal unwind label %unwind
normal:
  %field = getelementptr inbounds i8, ptr addrspace(1) %outer, i64 16
  store atomic ptr addrspace(1) %dst, ptr addrspace(1) %field unordered, align 8
  br label %return
unwind:
  %ex = landingpad i64 cleanup
  br label %return
return:
  ret ptr addrspace(1) %outer
exit:
  %exit.ex = landingpad i64 cleanup
  resume i64 %exit.ex
}

attributes #0 = { "jeandle.copy.kind"="arraycopy" "jeandle.copy.validated" }
!java-method-compilation = !{}
