; RUN: opt -S -passes="type-check-elimination" -jeandle-vm-callback-log=%S/Inputs/null-both-edges.cblog %s 2>&1 | FileCheck %s

; Both predecessors of %pass prove %obj null on their incoming edge. Null edges
; carry no non-null type constraint, so nothing is known at %pass and the query
; must NOT fold. JavaType cannot represent "known null" (MaybeNull is future
; work), so an all-null-edge merge must stay unknown — this pins the semantic
; intent; behaviorally the same output would also result from null arms merely
; contributing empty facts (the null-skip itself is pinned by
; null-threaded-edge.ll, where skipping the null arm is what enables the fold).

declare i1 @jeandle.check_instanceof(ptr addrspace(0), ptr addrspace(1) nonnull)

define i1 @test(ptr addrspace(1) %obj, i1 %c) gc "hotspotgc" {
entry:
  br i1 %c, label %A, label %B

A:
  %na = icmp eq ptr addrspace(1) %obj, null
  br i1 %na, label %pass, label %exit

B:
  %nb = icmp eq ptr addrspace(1) %obj, null
  br i1 %nb, label %pass, label %exit

pass:
  %r = call i1 @jeandle.check_instanceof(ptr addrspace(0) inttoptr (i64 22 to ptr addrspace(0)), ptr addrspace(1) nonnull %obj)
  ret i1 %r

exit:
  ret i1 false
}

; CHECK: pass:
; CHECK-NEXT:   %r = call i1 @jeandle.check_instanceof
; CHECK-NEXT:   ret i1 %r

!java-method-compilation = !{}
