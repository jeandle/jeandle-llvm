; RUN: opt -S -passes="type-check-elimination" -jeandle-vm-callback-log=%S/Inputs/phi-exact-base-guard.cblog %s 2>&1 | FileCheck %s

; An exact base type survives composition with an instanceof guard naming the
; same klass: the incoming %x is exactly klass 22 (!java-klass-exact), and the
; guard on the A->M edge only proves instanceof(22) — a strictly weaker claim.
; Exactness is what lets the query for the unrelated interface 33 fold to
; false.

declare i1 @jeandle.check_instanceof(ptr addrspace(0), ptr addrspace(1) nonnull)

define i1 @test(ptr addrspace(0) %p0, ptr addrspace(0) %p1, i1 %c) gc "hotspotgc" {
entry:
  br i1 %c, label %A, label %B

A:
  %x = load ptr addrspace(1), ptr addrspace(0) %p0, !java-klass !0, !java-klass-exact !2
  %ck = call i1 @jeandle.check_instanceof(ptr addrspace(0) inttoptr (i64 22 to ptr addrspace(0)), ptr addrspace(1) nonnull %x)
  br i1 %ck, label %M, label %exit

B:
  %y = load ptr addrspace(1), ptr addrspace(0) %p1, !java-klass !0, !java-klass-exact !2
  br label %M

M:
  %p = phi ptr addrspace(1) [ %x, %A ], [ %y, %B ]
  %res = call i1 @jeandle.check_instanceof(ptr addrspace(0) inttoptr (i64 33 to ptr addrspace(0)), ptr addrspace(1) nonnull %p)
  ret i1 %res

exit:
  ret i1 false
}

; %p stays exactly klass 22, so the interface query folds to false.
; CHECK: M:
; CHECK-NEXT:   %p = phi ptr addrspace(1)
; CHECK-NEXT:   ret i1 false

!java-method-compilation = !{}
!0 = !{i64 22}
!2 = !{}
