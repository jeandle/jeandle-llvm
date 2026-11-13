; RUN: opt -S -verify-each -passes="constant-field-folding" -jeandle-vm-callback-log=%S/Inputs/load-klass.cblog %s | FileCheck %s
;
; Later frame-state/JavaOp uses must not hide the non-null path fact at the
; Klass query. ValueTracking deliberately caps its scan of dominating uses.

declare ptr @jeandle.load_klass(ptr addrspace(1))
declare void @observe(...)

define ptr @guarded_many_uses(ptr addrspace(1) "java-klass"="123456" "java-klass-exact" %obj) {
entry:
  %null = icmp eq ptr addrspace(1) %obj, null
  br i1 %null, label %is_null, label %not_null
is_null:
  ret ptr null
not_null:
  %klass = call ptr @jeandle.load_klass(ptr addrspace(1) %obj)
  call void (...) @observe(
      ptr addrspace(1) %obj, ptr addrspace(1) %obj, ptr addrspace(1) %obj,
      ptr addrspace(1) %obj, ptr addrspace(1) %obj, ptr addrspace(1) %obj,
      ptr addrspace(1) %obj, ptr addrspace(1) %obj, ptr addrspace(1) %obj,
      ptr addrspace(1) %obj, ptr addrspace(1) %obj, ptr addrspace(1) %obj,
      ptr addrspace(1) %obj, ptr addrspace(1) %obj, ptr addrspace(1) %obj,
      ptr addrspace(1) %obj, ptr addrspace(1) %obj, ptr addrspace(1) %obj,
      ptr addrspace(1) %obj, ptr addrspace(1) %obj, ptr addrspace(1) %obj,
      ptr addrspace(1) %obj, ptr addrspace(1) %obj, ptr addrspace(1) %obj)
  ret ptr %klass
}

; CHECK-LABEL: define ptr @guarded_many_uses(
; CHECK: is_null:
; CHECK-NEXT: ret ptr null
; CHECK: not_null:
; CHECK-NEXT: call void (...) @observe(
; CHECK: ret ptr inttoptr (i64 123456 to ptr)

!java-method-compilation = !{}
