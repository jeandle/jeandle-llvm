; RUN: opt -S -passes="type-check-elimination" -jeandle-vm-callback-log=%S/Inputs/exclusions-merge.cblog %s 2>&1 | FileCheck %s

; Exclusion sets merge across edges: at M the value is known to be neither 22
; (A's false edge) nor 5 (B's false edge). Since 22 is a subtype of 5, the
; subtype-aware intersection keeps {22}. A query for klass 30 (a subtype of 22)
; is then denied by the exclusion and folds to false.

declare i1 @jeandle.check_instanceof(ptr addrspace(0), ptr addrspace(1) nonnull)

define i1 @test(ptr addrspace(1) "java-klass"="1" %obj, i1 %c) gc "hotspotgc" {
entry:
  br i1 %c, label %A, label %B

A:
  %ca = call i1 @jeandle.check_instanceof(ptr addrspace(0) inttoptr (i64 22 to ptr addrspace(0)), ptr addrspace(1) nonnull %obj)
  br i1 %ca, label %exit, label %M

B:
  %cb = call i1 @jeandle.check_instanceof(ptr addrspace(0) inttoptr (i64 5 to ptr addrspace(0)), ptr addrspace(1) nonnull %obj)
  br i1 %cb, label %exit, label %M

M:
  %r = call i1 @jeandle.check_instanceof(ptr addrspace(0) inttoptr (i64 30 to ptr addrspace(0)), ptr addrspace(1) nonnull %obj)
  ret i1 %r

exit:
  ret i1 true
}

; The arm checks stay; the query at M folds to false via the merged exclusion.
; CHECK: A:
; CHECK-NEXT:   %ca = call i1 @jeandle.check_instanceof
; CHECK: B:
; CHECK-NEXT:   %cb = call i1 @jeandle.check_instanceof
; CHECK: M:
; CHECK-NEXT:   ret i1 false

!java-method-compilation = !{}
