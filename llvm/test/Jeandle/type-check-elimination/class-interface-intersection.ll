; RUN: opt -S -passes=type-check-elimination -jeandle-vm-callback-log=%S/Inputs/class-interface-intersection.cblog %s | FileCheck %s
declare i1 @jeandle.check_instanceof(ptr, ptr addrspace(1) nonnull)
define i1 @class_interface(ptr addrspace(1) "java-klass"="9" %obj) {
entry:
  %is_i = call i1 @jeandle.check_instanceof(ptr inttoptr (i64 7 to ptr), ptr addrspace(1) nonnull %obj)
  br i1 %is_i, label %yes, label %no
yes:
  %is_c = call i1 @jeandle.check_instanceof(ptr inttoptr (i64 9 to ptr), ptr addrspace(1) nonnull %obj)
  ret i1 %is_c
no:
  ret i1 false
}
; CHECK-LABEL: define i1 @class_interface
; CHECK: yes:
; CHECK-NEXT: ret i1 true
!java-method-compilation = !{}
