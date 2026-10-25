; RUN: opt -S -passes=type-check-elimination -jeandle-vm-callback-log=%S/Inputs/context-phi-select.cblog %s | FileCheck %s
declare i1 @jeandle.check_instanceof(ptr, ptr addrspace(1) nonnull)
define i1 @wrapped(ptr addrspace(1) %obj, ptr addrspace(1) "java-klass"="9" %known, i1 %choose) {
entry:
  %check = call i1 @jeandle.check_instanceof(ptr inttoptr (i64 9 to ptr), ptr addrspace(1) nonnull %obj)
  br i1 %check, label %pass, label %fail
pass:
  br label %merge
merge:
  %p = phi ptr addrspace(1) [ %obj, %pass ]
  %s = select i1 %choose, ptr addrspace(1) %p, ptr addrspace(1) %known
  %again = call i1 @jeandle.check_instanceof(ptr inttoptr (i64 9 to ptr), ptr addrspace(1) nonnull %s)
  ret i1 %again
fail:
  ret i1 false
}
; CHECK-LABEL: define i1 @wrapped
; CHECK: merge:
; CHECK-NOT: call i1 @jeandle.check_instanceof
; CHECK: ret i1 true
!java-method-compilation = !{}
