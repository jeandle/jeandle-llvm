; RUN: opt -S -passes="type-check-elimination" -jeandle-vm-callback-log=%S/Inputs/merge-of-merge.cblog %s 2>&1 | FileCheck %s

; Merge-of-merge nesting. M1's predecessors both prove check(22); M1 then
; forks to C/D which both prove check(22) again before merging at M2. The edge
; facts must propagate through the inner merge M1 to C/D and on to M2.

declare i1 @jeandle.check_instanceof(ptr addrspace(0), ptr addrspace(1) nonnull)

define i1 @test(ptr addrspace(1) "java-klass"="1" %obj, i1 %c0, i1 %c1) gc "hotspotgc" {
entry:
  br i1 %c0, label %A, label %B

A:
  %ca = call i1 @jeandle.check_instanceof(ptr addrspace(0) inttoptr (i64 22 to ptr addrspace(0)), ptr addrspace(1) nonnull %obj)
  br i1 %ca, label %M1, label %exit

B:
  %cb = call i1 @jeandle.check_instanceof(ptr addrspace(0) inttoptr (i64 22 to ptr addrspace(0)), ptr addrspace(1) nonnull %obj)
  br i1 %cb, label %M1, label %exit

M1:
  br i1 %c1, label %C, label %D

C:
  %cc = call i1 @jeandle.check_instanceof(ptr addrspace(0) inttoptr (i64 22 to ptr addrspace(0)), ptr addrspace(1) nonnull %obj)
  br i1 %cc, label %M2, label %exit

D:
  %cd = call i1 @jeandle.check_instanceof(ptr addrspace(0) inttoptr (i64 22 to ptr addrspace(0)), ptr addrspace(1) nonnull %obj)
  br i1 %cd, label %M2, label %exit

M2:
  %r = call i1 @jeandle.check_instanceof(ptr addrspace(0) inttoptr (i64 22 to ptr addrspace(0)), ptr addrspace(1) nonnull %obj)
  ret i1 %r

exit:
  ret i1 false
}

; The outer arm checks are above the inner merge: nothing is known there.
; CHECK: A:
; CHECK-NEXT:   %ca = call i1 @jeandle.check_instanceof
; CHECK: B:
; CHECK-NEXT:   %cb = call i1 @jeandle.check_instanceof
; The inner arm checks already see the merged {22} fact from M1 and fold...
; CHECK: C:
; CHECK-NEXT:   br i1 true, label %M2, label %exit
; CHECK: D:
; CHECK-NEXT:   br i1 true, label %M2, label %exit
; ...and so does the query at the outer merge M2.
; CHECK: M2:
; CHECK-NEXT:   ret i1 true

!java-method-compilation = !{}
