; RUN: opt -S -passes="type-check-elimination" -jeandle-vm-callback-log=%S/Inputs/phi-mixed-stack-incoming.cblog %s 2>&1 | FileCheck %s

; The value dimension's recursion stack must not leak into a base-type root
; computation. %inc's base computation reaches %m, whose %pn2 incoming is a
; back edge only of the base root's own recursion. If the outer phiValueType
; stack were shared, %pn2 would be mistaken for a cycle there, %m (and %inc)
; would cache the too-narrow {22} that drops the loop-carried contribution,
; and the second %pn2 arm would reuse the cached value and wrongly fold the
; query. With a fresh stack the data cycle closes inside the base recursion,
; every arm bails to unknown, and the query stays.

declare i1 @jeandle.check_instanceof(ptr addrspace(0), ptr addrspace(1) nonnull)

define i1 @test(ptr addrspace(0) %p0, i1 %c1, i1 %c3) gc "hotspotgc" {
entry:
  %t = load ptr addrspace(1), ptr addrspace(0) %p0, !java-klass !0
  br label %PA

PA:
  br label %MB

; Loop back edge only: reached from Q, so %pn2 (defined in Q) dominates RC.
RC:
  br label %MB

MB:
  ; preds = PA (loop entry), RC (loop back edge)
  %m = phi ptr addrspace(1) [ %t, %PA ], [ %pn2, %RC ]
  %inc = freeze ptr addrspace(1) %m
  br i1 %c1, label %Q, label %MB2

MB2:
  br label %Q

Q:
  ; Both arms carry the same %inc, so a poisoned base-type cache for %inc
  ; would be reused by the second arm within the same query.
  %pn2 = phi ptr addrspace(1) [ %inc, %MB ], [ %inc, %MB2 ]
  br i1 %c3, label %RC, label %Done

Done:
  %r = call i1 @jeandle.check_instanceof(ptr addrspace(0) inttoptr (i64 22 to ptr addrspace(0)), ptr addrspace(1) nonnull %pn2)
  ret i1 %r
}

; The loop-carried %pn2 contribution keeps the value dimension unknown: the
; query stays.
; CHECK: Done:
; CHECK-NEXT:   %r = call i1 @jeandle.check_instanceof
; CHECK-NEXT:   ret i1 %r

!java-method-compilation = !{}
!0 = !{i64 22}
