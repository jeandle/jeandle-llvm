; RUN: opt -S -verify-each -passes="require<partial-escape-analysis>,partial-escape-transform" -jeandle-vm-callback-log=%S/Inputs/807_copy_fold_packed_groups.cblog %s | FileCheck %s --check-prefix=CHECK
; RUN: sed 's/e-p:64:64/E-p:64:64/' %s | opt -S -verify-each -passes="require<partial-escape-analysis>,partial-escape-transform" -jeandle-vm-callback-log=%S/Inputs/807_copy_fold_packed_groups.cblog | FileCheck %s --check-prefix=CHECK

; CHECK-LABEL: define i16 @whole_packed(
; CHECK-NOT: @jeandle.new_array
; CHECK-NOT: @jeandle.copy
; CHECK: ret i16 8721

target datalayout = "e-p:64:64"
declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32, i1, i1)
declare void @jeandle.copy(ptr addrspace(1), i64, ptr addrspace(1), i64, i64, ptr, ptr, i64, i64)
declare i32 @__gxx_personality_v0(...)
define i16 @whole_packed() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %src = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 12345 to ptr), i32 4, i32 32, i32 16, i32 1048576, i1 false, i1 false)
      to label %alloc unwind label %u
alloc:
  %dst = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 12345 to ptr), i32 4, i32 32, i32 16, i32 1048576, i1 false, i1 false)
      to label %init unwind label %u
init:
  %sp = getelementptr inbounds i8, ptr addrspace(1) %src, i64 16
  store atomic i16 8721, ptr addrspace(1) %sp unordered, align 1
  invoke void @jeandle.copy(ptr addrspace(1) %src, i64 0, ptr addrspace(1) %dst, i64 0, i64 2, ptr null, ptr null, i64 4, i64 4)
      #0 to label %read unwind label %u
read:
  %dp = getelementptr inbounds i8, ptr addrspace(1) %dst, i64 16
  %v = load atomic i16, ptr addrspace(1) %dp unordered, align 1
  ret i16 %v
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}
attributes #0 = { "jeandle.copy.kind"="arraycopy" "jeandle.copy.validated" }
!java-method-compilation = !{}

; CHECK-LABEL: define i16 @replace_bytes_with_group(
; CHECK-NOT: @jeandle.new_array
; CHECK-NOT: @jeandle.copy
; CHECK: ret i16 %value
define i16 @replace_bytes_with_group(i16 %value) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %src = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 12345 to ptr), i32 4, i32 32, i32 16, i32 1048576, i1 false, i1 false)
      to label %alloc unwind label %u
alloc:
  %dst = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 12345 to ptr), i32 4, i32 32, i32 16, i32 1048576, i1 false, i1 false)
      to label %init unwind label %u
init:
  %sp = getelementptr inbounds i8, ptr addrspace(1) %src, i64 16
  %d0 = getelementptr inbounds i8, ptr addrspace(1) %dst, i64 16
  %d1 = getelementptr inbounds i8, ptr addrspace(1) %dst, i64 17
  store atomic i8 99, ptr addrspace(1) %d0 unordered, align 1
  store atomic i8 88, ptr addrspace(1) %d1 unordered, align 1
  store atomic i16 %value, ptr addrspace(1) %sp unordered, align 1
  invoke void @jeandle.copy(ptr addrspace(1) %src, i64 0, ptr addrspace(1) %dst, i64 0, i64 2, ptr null, ptr null, i64 4, i64 4)
      #0 to label %read unwind label %u
read:
  %dp = getelementptr inbounds i8, ptr addrspace(1) %dst, i64 16
  %v = load atomic i16, ptr addrspace(1) %dp unordered, align 1
  ret i16 %v
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}
; CHECK-LABEL: define i8 @replace_group_with_bytes(
; CHECK-NOT: @jeandle.new_array
; CHECK-NOT: @jeandle.copy
; CHECK: ret i8 %value
define i8 @replace_group_with_bytes(i8 %value) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %src = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 12345 to ptr), i32 4, i32 32, i32 16, i32 1048576, i1 false, i1 false)
      to label %alloc unwind label %u
alloc:
  %dst = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 12345 to ptr), i32 4, i32 32, i32 16, i32 1048576, i1 false, i1 false)
      to label %init unwind label %u
init:
  %sp = getelementptr inbounds i8, ptr addrspace(1) %src, i64 16
  %old = getelementptr inbounds i8, ptr addrspace(1) %dst, i64 16
  store atomic i16 8721, ptr addrspace(1) %old unordered, align 1
  store atomic i8 %value, ptr addrspace(1) %sp unordered, align 1
  invoke void @jeandle.copy(ptr addrspace(1) %src, i64 0, ptr addrspace(1) %dst, i64 0, i64 2, ptr null, ptr null, i64 4, i64 4)
      #0 to label %read unwind label %u
read:
  %dp = getelementptr inbounds i8, ptr addrspace(1) %dst, i64 16
  %v = load atomic i8, ptr addrspace(1) %dp unordered, align 1
  ret i8 %v
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}
; CHECK-LABEL: define i16 @packed_overlap(
; CHECK-NOT: @jeandle.new_array
; CHECK-NOT: @jeandle.copy
; CHECK: ret i16 %value
define i16 @packed_overlap(i16 %value) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %src = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 12345 to ptr), i32 4, i32 32, i32 16, i32 1048576, i1 false, i1 false)
      to label %alloc unwind label %u
alloc:
  %dst = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 12345 to ptr), i32 4, i32 32, i32 16, i32 1048576, i1 false, i1 false)
      to label %init unwind label %u
init:
  %sp = getelementptr inbounds i8, ptr addrspace(1) %src, i64 16
  store atomic i16 %value, ptr addrspace(1) %sp unordered, align 1
  invoke void @jeandle.copy(ptr addrspace(1) %src, i64 0, ptr addrspace(1) %src, i64 2, i64 2, ptr null, ptr null, i64 4, i64 4)
      #0 to label %read unwind label %u
read:
  %dp = getelementptr inbounds i8, ptr addrspace(1) %src, i64 18
  %v = load atomic i16, ptr addrspace(1) %dp unordered, align 1
  ret i16 %v
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}
; CHECK-LABEL: define ptr addrspace(1) @packed_escape(
; CHECK: @jeandle.new_array
; CHECK-NOT: @jeandle.copy
; CHECK: store atomic i16 %value
; CHECK: ret ptr addrspace(1) %dst
define ptr addrspace(1) @packed_escape(i16 %value) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %src = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 12345 to ptr), i32 4, i32 32, i32 16, i32 1048576, i1 false, i1 false)
      to label %alloc unwind label %u
alloc:
  %dst = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 12345 to ptr), i32 4, i32 32, i32 16, i32 1048576, i1 false, i1 false)
      to label %init unwind label %u
init:
  %sp = getelementptr inbounds i8, ptr addrspace(1) %src, i64 16
  store atomic i16 %value, ptr addrspace(1) %sp unordered, align 1
  invoke void @jeandle.copy(ptr addrspace(1) %src, i64 0, ptr addrspace(1) %dst, i64 0, i64 2, ptr null, ptr null, i64 4, i64 4)
      #0 to label %read unwind label %u
read:
  %dp = getelementptr inbounds i8, ptr addrspace(1) %dst, i64 16
  ret ptr addrspace(1) %dst
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}