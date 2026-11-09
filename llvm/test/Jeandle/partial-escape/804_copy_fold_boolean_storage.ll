; RUN: opt -S -verify-each -passes="require<partial-escape-analysis>,partial-escape-transform" -jeandle-vm-callback-log=%S/Inputs/804_copy_fold_boolean_storage.cblog %s | FileCheck %s

; CHECK-LABEL: define i8 @v2v(
; CHECK-NOT: @jeandle.new_array
; CHECK-NOT: @jeandle.copy
; CHECK: ret i8 1
; CHECK-LABEL: define i8 @concrete(
; CHECK-NOT: @jeandle.new_array
; CHECK-NOT: @jeandle.copy
; CHECK: load atomic i8

target datalayout = "e-p:64:64"
declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32)
declare void @jeandle.copy(ptr addrspace(1), i64, ptr addrspace(1), i64, i64, ptr, ptr, i64, i64)
declare i32 @__gxx_personality_v0(...)
define i8 @v2v() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %src = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 12345 to ptr), i32 2, i32 24, i32 16, i32 1048576) to label %init unwind label %u
init:
  %sp = getelementptr inbounds i8, ptr addrspace(1) %src, i64 16
  store atomic i8 1, ptr addrspace(1) %sp unordered, align 1
  %dst = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 12345 to ptr), i32 2, i32 24, i32 16, i32 1048576) to label %copy unwind label %u
copy:
  invoke void @jeandle.copy(ptr addrspace(1) %src, i64 0, ptr addrspace(1) %dst, i64 0, i64 2, ptr null, ptr null, i64 2, i64 2) #0 to label %read unwind label %u
read:
  %dp = getelementptr inbounds i8, ptr addrspace(1) %dst, i64 16
  %v = load atomic i8, ptr addrspace(1) %dp unordered, align 1
  ret i8 %v
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}
define i8 @concrete(ptr addrspace(1) "java-klass"="12345" %src) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %dst = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 12345 to ptr), i32 2, i32 24, i32 16, i32 1048576) to label %copy unwind label %u
copy:
  invoke void @jeandle.copy(ptr addrspace(1) %src, i64 0, ptr addrspace(1) %dst, i64 0, i64 2, ptr null, ptr null, i64 2, i64 2) #0 to label %read unwind label %u
read:
  %dp = getelementptr inbounds i8, ptr addrspace(1) %dst, i64 16
  %v = load atomic i8, ptr addrspace(1) %dp unordered, align 1
  ret i8 %v
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}
attributes #0 = { "jeandle.copy.kind"="arraycopy" "jeandle.copy.validated" }
!java-method-compilation = !{}
