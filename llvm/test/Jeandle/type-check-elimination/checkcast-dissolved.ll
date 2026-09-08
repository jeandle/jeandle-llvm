; RUN: opt -S -passes="type-check-elimination" -jeandle-vm-callback-log=%S/Inputs/checkcast-dissolved.cblog %s 2>&1 | FileCheck %s

; A phase-0 checkcast after SimplifyCFG dissolution: %pass has two
; predecessors — the null edge from %site (no non-null type constraint,
; skipped) and the check edge from %check_subtype proving klass 22 — and no
; edge dominates %pass. The query in %pass folds via the union of the
; non-null incoming edges.

declare i1 @jeandle.check_instanceof(ptr addrspace(0), ptr addrspace(1) nonnull)

define i1 @test(ptr addrspace(1) %obj) gc "hotspotgc" {
site:
  %is_null = icmp eq ptr addrspace(1) %obj, null
  br i1 %is_null, label %pass, label %check_subtype

check_subtype:
  %is_sub = call i1 @jeandle.check_instanceof(ptr addrspace(0) inttoptr (i64 22 to ptr addrspace(0)), ptr addrspace(1) nonnull %obj)
  br i1 %is_sub, label %pass, label %fail

pass:
  %r = call i1 @jeandle.check_instanceof(ptr addrspace(0) inttoptr (i64 22 to ptr addrspace(0)), ptr addrspace(1) nonnull %obj)
  ret i1 %r

fail:
  ret i1 false
}

; The check in %check_subtype is preserved (its own site proves nothing); the
; query in %pass folds.
; CHECK: check_subtype:
; CHECK-NEXT:   %is_sub = call i1 @jeandle.check_instanceof
; CHECK: pass:
; CHECK-NEXT:   ret i1 true

!java-method-compilation = !{}
