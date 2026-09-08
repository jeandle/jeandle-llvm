; RUN: opt -S -passes="type-check-elimination" -jeandle-vm-callback-log=%S/Inputs/null-threaded-edge.cblog %s 2>&1 | FileCheck %s

; The null edge reaches %pass through an empty intermediate block (threaded
; shape). The structural fast path cannot see it (%nullbb's terminator is an
; unconditional branch), so the LazyValueInfo-backed oracle must prove
; %obj == null on nullbb -> %pass for the fold to happen. Without the oracle
; this query stays unknown.

declare i1 @jeandle.check_instanceof(ptr addrspace(0), ptr addrspace(1) nonnull)

define i1 @test(ptr addrspace(1) %obj) gc "hotspotgc" {
site:
  %is_null = icmp eq ptr addrspace(1) %obj, null
  br i1 %is_null, label %nullbb, label %check_subtype

nullbb:
  br label %pass

check_subtype:
  %is_sub = call i1 @jeandle.check_instanceof(ptr addrspace(0) inttoptr (i64 22 to ptr addrspace(0)), ptr addrspace(1) nonnull %obj)
  br i1 %is_sub, label %pass, label %fail

pass:
  %r = call i1 @jeandle.check_instanceof(ptr addrspace(0) inttoptr (i64 22 to ptr addrspace(0)), ptr addrspace(1) nonnull %obj)
  ret i1 %r

fail:
  ret i1 false
}

; CHECK: check_subtype:
; CHECK-NEXT:   %is_sub = call i1 @jeandle.check_instanceof
; CHECK: pass:
; CHECK-NEXT:   ret i1 true

!java-method-compilation = !{}
