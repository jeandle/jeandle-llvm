; RUN: opt -S -passes=type-check-elimination -jeandle-vm-callback-log=%S/Inputs/array-interface-overlap.cblog %s | FileCheck %s
; An A[] value can be D[] where D extends A and implements I.
declare i1 @jeandle.check_instanceof(ptr, ptr addrspace(1) nonnull)
define i1 @array_overlap(ptr addrspace(1) "java-klass"="9" %obj) {
  %r = call i1 @jeandle.check_instanceof(ptr inttoptr (i64 7 to ptr), ptr addrspace(1) nonnull %obj)
  ret i1 %r
}
; CHECK-LABEL: define i1 @array_overlap
; CHECK: %r = call i1 @jeandle.check_instanceof
; CHECK: ret i1 %r
!java-method-compilation = !{}
