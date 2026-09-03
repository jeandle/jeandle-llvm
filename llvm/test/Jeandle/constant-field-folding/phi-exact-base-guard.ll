; RUN: opt -S -passes="constant-field-folding" -jeandle-vm-callback-log=%S/Inputs/phi-exact-base-guard.cblog %s 2>&1 | FileCheck %s

; An exact base type survives composition with an instanceof guard naming the
; same klass: the incoming %x is exactly klass 22 (!java-klass-exact), and the
; guard on the A->M edge only proves instanceof(22) — a strictly weaker claim.
; ConstantFieldFolding requires Exact to fold jeandle.load_klass, so the fold
; happening proves exactness was preserved through the merge.

declare i1 @jeandle.check_instanceof(ptr addrspace(0), ptr addrspace(1) nonnull)
declare ptr @jeandle.load_klass(ptr addrspace(1))

define ptr @test(ptr addrspace(0) %p0, ptr addrspace(0) %p1, i1 %c) #0 gc "hotspotgc" {
entry:
  br i1 %c, label %A, label %B

A:
  %x = load ptr addrspace(1), ptr addrspace(0) %p0, !nonnull !2, !java-klass !0, !java-klass-exact !2
  %ck = call i1 @jeandle.check_instanceof(ptr addrspace(0) inttoptr (i64 22 to ptr addrspace(0)), ptr addrspace(1) nonnull %x)
  br i1 %ck, label %M, label %exit

B:
  %y = load ptr addrspace(1), ptr addrspace(0) %p1, !nonnull !2, !java-klass !0, !java-klass-exact !2
  br label %M

M:
  %p = phi ptr addrspace(1) [ %x, %A ], [ %y, %B ]
  %lk = call ptr @jeandle.load_klass(ptr addrspace(1) %p)
  ret ptr %lk

exit:
  ret ptr null
}

; The load_klass call folds to the klass constant, which requires the merged
; type to still be Exact.
; CHECK: M:
; CHECK-NEXT:   %p = phi ptr addrspace(1)
; CHECK-NEXT:   ret ptr inttoptr (i64 555 to ptr)

attributes #0 = { "java-method"="0" }

!java-method-compilation = !{}
!0 = !{i64 22}
!2 = !{}
