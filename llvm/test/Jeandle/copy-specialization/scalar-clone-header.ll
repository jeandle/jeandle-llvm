; RUN: opt -S -verify-each -passes=copy-specialization -jeandle-vm-callback-log=%S/Inputs/primitive-array-clone.cblog %s | FileCheck %s
; RUN: sed 's/@VMOptions.ReduceBulkZeroing = constant i1 true/@VMOptions.ReduceBulkZeroing = constant i1 false/' %s | opt -S -verify-each -passes=copy-specialization -jeandle-vm-callback-log=%S/Inputs/primitive-array-clone.cblog | FileCheck %s

@VMOptions.ReduceBulkZeroing = constant i1 true
@VMOptions.ArrayCopyLoadStoreMaxElem = constant i32 8
@arrayOopDesc.length_offset_in_bytes = constant i32 16
@arrayOopDesc.base_offset_in_bytes.int = constant i32 24

declare ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32, i1, i1)
declare i32 @jeandle.arraylength(ptr addrspace(1))
declare void @jeandle.copy(ptr addrspace(1), i64, ptr addrspace(1), i64, i64, ptr, ptr, i64, i64)
define void @jeandle.clone_payload(ptr addrspace(1) %src, i64 %so, ptr addrspace(1) %dst, i64 %do, i64 %words, i1 %instance) nounwind "gc-leaf-function" {
  ret void
}

; Scalarization may omit a length-header write only with equal lengths.
define ptr addrspace(1) @same_length() #0 {
  %src = call "java-klass"="103" ptr addrspace(1) @jeandle.new_array(ptr null, i32 3, i32 40, i32 24, i32 1000, i1 false, i1 false)
  %length = call i32 @jeandle.arraylength(ptr addrspace(1) %src)
  %dst = call ptr addrspace(1) @jeandle.new_array(ptr null, i32 %length, i32 40, i32 24, i32 1000, i1 false, i1 false)
  call void @jeandle.copy(ptr addrspace(1) %src, i64 16, ptr addrspace(1) %dst, i64 16, i64 3, ptr null, ptr null, i64 36, i64 36) #1
  ret ptr addrspace(1) %dst
}
; CHECK-LABEL: define ptr addrspace(1) @same_length(
; CHECK: getelementptr i8, ptr addrspace(1) %src, i64 24
; CHECK: load atomic volatile i64, {{.*}} unordered, align 8
; CHECK: store atomic i64 {{.*}} unordered, align 8
; CHECK: load atomic volatile i32, {{.*}} unordered, align 4
; CHECK: store atomic i32 {{.*}} unordered, align 4
; CHECK-NOT: load atomic
; CHECK-NOT: @jeandle.clone_payload
; CHECK: ret ptr addrspace(1) %dst

define ptr addrspace(1) @different_length() #0 {
  %src = call "java-klass"="103" ptr addrspace(1) @jeandle.new_array(ptr null, i32 4, i32 40, i32 24, i32 1000, i1 false, i1 false)
  %dst = call ptr addrspace(1) @jeandle.new_array(ptr null, i32 3, i32 40, i32 24, i32 1000, i1 false, i1 false)
  call void @jeandle.copy(ptr addrspace(1) %src, i64 16, ptr addrspace(1) %dst, i64 16, i64 3, ptr null, ptr null, i64 36, i64 36) #1
  ret ptr addrspace(1) %dst
}
; CHECK-LABEL: define ptr addrspace(1) @different_length(
; CHECK-NOT: load atomic
; CHECK: call hotspotcc void @jeandle.clone_payload(

attributes #0 = { "java-method"="0" }
attributes #1 = { "jeandle.copy.kind"="clone-array" "jeandle.copy.tightly-coupled-allocation" }
!java-method-compilation = !{}
