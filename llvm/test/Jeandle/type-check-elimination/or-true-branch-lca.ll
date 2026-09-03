; RUN: opt -S -passes="type-check-elimination" -jeandle-vm-callback-log=%S/Inputs/or-true-branch-lca.cblog %s 2>&1 | FileCheck %s

; Or-true-branch merge: `obj instanceof 22 || obj instanceof 9`. %pass is
; reachable from the true edge of either check, so the engine joins {22} and
; {9} to LCA(22, 9) = 5 and the instanceof-5 query folds to true. This is
; sound because instanceof is false on null, so %pass is only reached with a
; non-null %obj.

declare i1 @jeandle.check_instanceof(ptr addrspace(0), ptr addrspace(1) nonnull)

define i1 @test(ptr addrspace(1) %obj) gc "hotspotgc" {
entry:
  %d = call i1 @jeandle.check_instanceof(ptr addrspace(0) inttoptr (i64 22 to ptr addrspace(0)), ptr addrspace(1) nonnull %obj)
  br i1 %d, label %pass, label %check_cat

check_cat:
  %c = call i1 @jeandle.check_instanceof(ptr addrspace(0) inttoptr (i64 9 to ptr addrspace(0)), ptr addrspace(1) nonnull %obj)
  br i1 %c, label %pass, label %fail

pass:
  %a = call i1 @jeandle.check_instanceof(ptr addrspace(0) inttoptr (i64 5 to ptr addrspace(0)), ptr addrspace(1) nonnull %obj)
  ret i1 %a

fail:
  ret i1 false
}

; The two guard checks stay; the query at %pass folds to true.
; CHECK: entry:
; CHECK-NEXT:   %d = call i1 @jeandle.check_instanceof
; CHECK: check_cat:
; CHECK-NEXT:   %c = call i1 @jeandle.check_instanceof
; CHECK: pass:
; CHECK-NEXT:   ret i1 true

!java-method-compilation = !{}
