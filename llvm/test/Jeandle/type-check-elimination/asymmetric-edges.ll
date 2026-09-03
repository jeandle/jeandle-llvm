; RUN: opt -S -passes="type-check-elimination" -jeandle-vm-callback-log=%S/Inputs/asymmetric-edges.cblog %s 2>&1 | FileCheck %s

; Asymmetric merge edges.
; f1: only one arm proves check(22); the other arm contributes nothing, so the
;     join is unknown and the query must NOT fold.
; f2: the arms prove check(22) and check(9) with 9 a subtype of 22, so the join
;     is LCA(22, 9) = 22: a query for 22 folds, a query for 9 must NOT fold.

declare i1 @jeandle.check_instanceof(ptr addrspace(0), ptr addrspace(1) nonnull)

define i1 @f1(ptr addrspace(1) "java-klass"="1" %obj, i1 %c) gc "hotspotgc" {
entry:
  br i1 %c, label %A, label %B

A:
  %ca = call i1 @jeandle.check_instanceof(ptr addrspace(0) inttoptr (i64 22 to ptr addrspace(0)), ptr addrspace(1) nonnull %obj)
  br i1 %ca, label %M, label %exit

B:
  br label %M

M:
  %r = call i1 @jeandle.check_instanceof(ptr addrspace(0) inttoptr (i64 22 to ptr addrspace(0)), ptr addrspace(1) nonnull %obj)
  ret i1 %r

exit:
  ret i1 false
}

define i1 @f2(ptr addrspace(1) "java-klass"="1" %obj, i1 %c) gc "hotspotgc" {
entry:
  br i1 %c, label %A, label %B

A:
  %ca = call i1 @jeandle.check_instanceof(ptr addrspace(0) inttoptr (i64 22 to ptr addrspace(0)), ptr addrspace(1) nonnull %obj)
  br i1 %ca, label %M, label %exit

B:
  %cb = call i1 @jeandle.check_instanceof(ptr addrspace(0) inttoptr (i64 9 to ptr addrspace(0)), ptr addrspace(1) nonnull %obj)
  br i1 %cb, label %M, label %exit

M:
  %r22 = call i1 @jeandle.check_instanceof(ptr addrspace(0) inttoptr (i64 22 to ptr addrspace(0)), ptr addrspace(1) nonnull %obj)
  %r9 = call i1 @jeandle.check_instanceof(ptr addrspace(0) inttoptr (i64 9 to ptr addrspace(0)), ptr addrspace(1) nonnull %obj)
  %res = and i1 %r22, %r9
  ret i1 %res

exit:
  ret i1 false
}

; f1: the unchecked arm poisons the join — both the arm check and the query
; stay.
; CHECK-LABEL: define i1 @f1(
; CHECK: A:
; CHECK-NEXT:   %ca = call i1 @jeandle.check_instanceof
; CHECK: M:
; CHECK-NEXT:   %r = call i1 @jeandle.check_instanceof
; CHECK-NEXT:   ret i1 %r

; f2: arm checks stay (nothing known above the merge); at M the join is 22, so
; the query for 22 folds and the query for 9 stays.
; CHECK-LABEL: define i1 @f2(
; CHECK: A:
; CHECK-NEXT:   %ca = call i1 @jeandle.check_instanceof
; CHECK: B:
; CHECK-NEXT:   %cb = call i1 @jeandle.check_instanceof
; CHECK: M:
; CHECK-NEXT:   %r9 = call i1 @jeandle.check_instanceof
; CHECK-NEXT:   %res = and i1 true, %r9
; CHECK-NEXT:   ret i1 %res

!java-method-compilation = !{}
