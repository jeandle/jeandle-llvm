; RUN: opt -S -verify-each -passes="require<partial-escape-analysis>,partial-escape-transform" -jeandle-vm-callback-log=%S/Inputs/807_copy_fold_packed_groups.cblog %s | FileCheck %s
; RUN: sed 's/e-p:64:64/E-p:64:64/' %s | opt -S -verify-each -passes="require<partial-escape-analysis>,partial-escape-transform" -jeandle-vm-callback-log=%S/Inputs/807_copy_fold_packed_groups.cblog | FileCheck %s

; Full replacement removes the old packed group, including default bytes.
; CHECK-LABEL: define i8 @chained_complete_groups(
; CHECK-NOT: @jeandle.new_array
; CHECK-NOT: @jeandle.copy
; CHECK: ret i8 0
target datalayout = "e-p:64:64"
declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32, i1, i1)
declare void @jeandle.copy(ptr addrspace(1), i64, ptr addrspace(1), i64, i64, ptr, ptr, i64, i64)
declare i32 @__gxx_personality_v0(...)
define i8 @chained_complete_groups(i8 %value) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %src = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 12345 to ptr), i32 4, i32 32, i32 16, i32 1048576, i1 false, i1 false)
      to label %alloc unwind label %u
alloc:
  %dst = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 12345 to ptr), i32 4, i32 32, i32 16, i32 1048576, i1 false, i1 false)
      to label %third_alloc unwind label %u
third_alloc:
  %last = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 12345 to ptr), i32 4, i32 32, i32 16, i32 1048576, i1 false, i1 false)
      to label %init unwind label %u
init:
  %sp = getelementptr inbounds i8, ptr addrspace(1) %src, i64 16
  %old = getelementptr inbounds i8, ptr addrspace(1) %dst, i64 16
  store atomic i16 8721, ptr addrspace(1) %old unordered, align 1
  store atomic i8 %value, ptr addrspace(1) %sp unordered, align 1
  invoke void @jeandle.copy(ptr addrspace(1) %src, i64 0, ptr addrspace(1) %dst, i64 0, i64 2, ptr null, ptr null, i64 4, i64 4)
      #0 to label %read unwind label %u
read:
  invoke void @jeandle.copy(ptr addrspace(1) %dst, i64 1, ptr addrspace(1) %last, i64 0, i64 1, ptr null, ptr null, i64 4, i64 4) #0 to label %finish unwind label %u
finish:
  %dp = getelementptr inbounds i8, ptr addrspace(1) %last, i64 16
  %v = load atomic i8, ptr addrspace(1) %dp unordered, align 1
  ret i8 %v
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

attributes #0 = { "jeandle.copy.kind"="arraycopy" "jeandle.copy.validated" }
!java-method-compilation = !{}

; A later ordinary store must use the current byte grouping as well.
; CHECK-LABEL: define i8 @store_after_group_replacement(
; CHECK-NOT: @jeandle.new_array
; CHECK-NOT: @jeandle.copy
; CHECK: ret i8 41
define i8 @store_after_group_replacement(i8 %value) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %src = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 12345 to ptr), i32 4, i32 32, i32 16, i32 1048576, i1 false, i1 false)
      to label %alloc unwind label %u
alloc:
  %dst = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 12345 to ptr), i32 4, i32 32, i32 16, i32 1048576, i1 false, i1 false)
      to label %third_alloc unwind label %u
third_alloc:
  %last = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 12345 to ptr), i32 4, i32 32, i32 16, i32 1048576, i1 false, i1 false)
      to label %init unwind label %u
init:
  %sp = getelementptr inbounds i8, ptr addrspace(1) %src, i64 16
  %old = getelementptr inbounds i8, ptr addrspace(1) %dst, i64 16
  store atomic i16 8721, ptr addrspace(1) %old unordered, align 1
  store atomic i8 %value, ptr addrspace(1) %sp unordered, align 1
  invoke void @jeandle.copy(ptr addrspace(1) %src, i64 0, ptr addrspace(1) %dst, i64 0, i64 2, ptr null, ptr null, i64 4, i64 4)
      #0 to label %read unwind label %u
read:
  %newcell = getelementptr inbounds i8, ptr addrspace(1) %dst, i64 17
  store atomic i8 41, ptr addrspace(1) %newcell unordered, align 1
  invoke void @jeandle.copy(ptr addrspace(1) %dst, i64 1, ptr addrspace(1) %last, i64 0, i64 1, ptr null, ptr null, i64 4, i64 4) #0 to label %finish unwind label %u
finish:
  %dp = getelementptr inbounds i8, ptr addrspace(1) %last, i64 16
  %v = load atomic i8, ptr addrspace(1) %dp unordered, align 1
  ret i8 %v
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; Branches have different histories and the same current layout.
; CHECK-LABEL: define i8 @branch_histories(
; CHECK-NOT: @jeandle.new_array
; CHECK-NOT: @jeandle.copy
; CHECK: ret i8 0
define i8 @branch_histories(i8 %value, i1 %choose) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %src = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 12345 to ptr), i32 4, i32 32, i32 16, i32 1048576, i1 false, i1 false)
      to label %alloc unwind label %u
alloc:
  %dst = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 12345 to ptr), i32 4, i32 32, i32 16, i32 1048576, i1 false, i1 false)
      to label %third_alloc unwind label %u
third_alloc:
  %last = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 12345 to ptr), i32 4, i32 32, i32 16, i32 1048576, i1 false, i1 false)
      to label %init unwind label %u
init:
  %sp = getelementptr inbounds i8, ptr addrspace(1) %src, i64 16
  %old = getelementptr inbounds i8, ptr addrspace(1) %dst, i64 16
  store atomic i8 %value, ptr addrspace(1) %sp unordered, align 1
  br i1 %choose, label %left, label %right
left:
  store atomic i16 8721, ptr addrspace(1) %old unordered, align 1
  invoke void @jeandle.copy(ptr addrspace(1) %src, i64 0, ptr addrspace(1) %dst, i64 0, i64 2, ptr null, ptr null, i64 4, i64 4)
      #0 to label %read unwind label %u
right:
  store atomic i8 %value, ptr addrspace(1) %old unordered, align 1
  br label %read
read:
  invoke void @jeandle.copy(ptr addrspace(1) %dst, i64 1, ptr addrspace(1) %last, i64 0, i64 1, ptr null, ptr null, i64 4, i64 4) #0 to label %finish unwind label %u
finish:
  %dp = getelementptr inbounds i8, ptr addrspace(1) %last, i64 16
  %v = load atomic i8, ptr addrspace(1) %dp unordered, align 1
  ret i8 %v
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}
