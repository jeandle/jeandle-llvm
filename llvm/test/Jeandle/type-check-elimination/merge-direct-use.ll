; RUN: opt -S -passes="type-check-elimination" -jeandle-vm-callback-log=%S/Inputs/merge-direct-use.cblog %s 2>&1 | FileCheck %s

; Both diamond arms reach the merge only along the true edge of a
; check_instanceof(22) on %obj. Edge-semantics sharpening unions the two
; per-edge facts {22} and folds the query.

declare i1 @jeandle.check_instanceof(ptr addrspace(0), ptr addrspace(1) nonnull)

define i1 @test(ptr addrspace(1) "java-klass"="1" %obj, i1 %c) gc "hotspotgc" {
entry:
  br i1 %c, label %A, label %B

A:
  %ca = call i1 @jeandle.check_instanceof(ptr addrspace(0) inttoptr (i64 22 to ptr addrspace(0)), ptr addrspace(1) nonnull %obj)
  br i1 %ca, label %M, label %exit

B:
  %cb = call i1 @jeandle.check_instanceof(ptr addrspace(0) inttoptr (i64 22 to ptr addrspace(0)), ptr addrspace(1) nonnull %obj)
  br i1 %cb, label %M, label %exit

M:
  %r = call i1 @jeandle.check_instanceof(ptr addrspace(0) inttoptr (i64 22 to ptr addrspace(0)), ptr addrspace(1) nonnull %obj)
  ret i1 %r

exit:
  ret i1 false
}

; The arm checks are preserved (nothing is known at their own sites)...
; CHECK: A:
; CHECK-NEXT:   %ca = call i1 @jeandle.check_instanceof
; CHECK: B:
; CHECK-NEXT:   %cb = call i1 @jeandle.check_instanceof
; ...but the query at the merge folds to true.
; CHECK: M:
; CHECK-NEXT:   ret i1 true

!java-method-compilation = !{}
