; RUN: opt -S -passes=type-check-elimination -jeandle-vm-callback-log=%S/Inputs/interface-only-facts.cblog %s | FileCheck %s
declare i1 @jeandle.check_instanceof(ptr, ptr addrspace(1) nonnull)
define i1 @interfaces(ptr addrspace(1) %obj) {
entry:
  %a = call i1 @jeandle.check_instanceof(ptr inttoptr (i64 7 to ptr), ptr addrspace(1) nonnull %obj)
  %b = call i1 @jeandle.check_instanceof(ptr inttoptr (i64 8 to ptr), ptr addrspace(1) nonnull %obj)
  %both = and i1 %a, %b
  br i1 %both, label %yes, label %no
yes:
  %again = call i1 @jeandle.check_instanceof(ptr inttoptr (i64 7 to ptr), ptr addrspace(1) nonnull %obj)
  ret i1 %again
no:
  ret i1 false
}
; CHECK-LABEL: define i1 @interfaces
; CHECK: yes:
; CHECK-NEXT: ret i1 true
!java-method-compilation = !{}
