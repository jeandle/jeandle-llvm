; RUN: opt -S -passes="type-check-elimination" -jeandle-vm-callback-log=%S/Inputs/null-guard-forms.cblog %s 2>&1 | FileCheck %s

; Null-edge recognition must see through pointer-cast wrappers on the tested
; pointer and accept the null constant on either operand side, including the
; threaded shape (null edge through an empty block). With the null arm
; skipped, the remaining arm's passing check folds the probe to true.

declare i1 @jeandle.check_instanceof(ptr addrspace(0), ptr addrspace(1) nonnull)

define i1 @threaded_asc_null(ptr addrspace(1) %obj) gc "hotspotgc" {
site:
  %asc = addrspacecast ptr addrspace(1) %obj to ptr addrspace(0)
  %is_null = icmp eq ptr %asc, null
  br i1 %is_null, label %nullbb, label %check_subtype
nullbb:
  br label %pass
check_subtype:
  %is_sub = call i1 @jeandle.check_instanceof(ptr addrspace(0) inttoptr (i64 22 to ptr addrspace(0)), ptr addrspace(1) nonnull %obj)
  br i1 %is_sub, label %pass, label %fail
pass:
  ; CHECK-LABEL: @threaded_asc_null(
  ; CHECK: pass:
  ; CHECK-NEXT: ret i1 true
  %r = call i1 @jeandle.check_instanceof(ptr addrspace(0) inttoptr (i64 22 to ptr addrspace(0)), ptr addrspace(1) nonnull %obj)
  ret i1 %r
fail:
  ret i1 false
}

define i1 @threaded_null_lhs(ptr addrspace(1) %obj) gc "hotspotgc" {
site:
  %is_null = icmp eq ptr addrspace(1) null, %obj
  br i1 %is_null, label %nullbb, label %check_subtype
nullbb:
  br label %pass
check_subtype:
  %is_sub = call i1 @jeandle.check_instanceof(ptr addrspace(0) inttoptr (i64 22 to ptr addrspace(0)), ptr addrspace(1) nonnull %obj)
  br i1 %is_sub, label %pass, label %fail
pass:
  ; CHECK-LABEL: @threaded_null_lhs(
  ; CHECK: pass:
  ; CHECK-NEXT: ret i1 true
  %r = call i1 @jeandle.check_instanceof(ptr addrspace(0) inttoptr (i64 22 to ptr addrspace(0)), ptr addrspace(1) nonnull %obj)
  ret i1 %r
fail:
  ret i1 false
}

!java-method-compilation = !{}
