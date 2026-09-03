; RUN: opt -S -passes="type-check-elimination" -jeandle-vm-callback-log=%S/Inputs/check-klass-subtype-const.cblog %s 2>&1 | FileCheck %s

; Constant-klass folding of jeandle.check_klass_subtype: with both operands
; constant klass pointers the check is a pure function of the two constants
; (a klass constant is an exact type; the runtime template computes the same
; primary/secondary-supers predicate), so it folds via the VM's IsSubtype
; callback. An interface super klass folds as well. A non-constant operand
; preserves the call. This module deliberately has no check_instanceof calls,
; which also pins the pass gate.

declare i1 @jeandle.check_klass_subtype(ptr addrspace(0), ptr addrspace(0))

define i1 @fold_true() gc "hotspotgc" {
  %r = call i1 @jeandle.check_klass_subtype(ptr addrspace(0) inttoptr (i64 22 to ptr addrspace(0)), ptr addrspace(0) inttoptr (i64 5 to ptr addrspace(0)))
  ret i1 %r
}

define i1 @fold_false() gc "hotspotgc" {
  %r = call i1 @jeandle.check_klass_subtype(ptr addrspace(0) inttoptr (i64 9 to ptr addrspace(0)), ptr addrspace(0) inttoptr (i64 22 to ptr addrspace(0)))
  ret i1 %r
}

define i1 @fold_interface_super() gc "hotspotgc" {
  %r = call i1 @jeandle.check_klass_subtype(ptr addrspace(0) inttoptr (i64 22 to ptr addrspace(0)), ptr addrspace(0) inttoptr (i64 44 to ptr addrspace(0)))
  ret i1 %r
}

define i1 @preserved(ptr addrspace(0) %sub) gc "hotspotgc" {
  %r = call i1 @jeandle.check_klass_subtype(ptr addrspace(0) %sub, ptr addrspace(0) inttoptr (i64 5 to ptr addrspace(0)))
  ret i1 %r
}

; CHECK-LABEL: define i1 @fold_true(
; CHECK-NEXT:   ret i1 true
; CHECK-LABEL: define i1 @fold_false(
; CHECK-NEXT:   ret i1 false
; CHECK-LABEL: define i1 @fold_interface_super(
; CHECK-NEXT:   ret i1 true
; CHECK-LABEL: define i1 @preserved(
; CHECK-NEXT:   %r = call i1 @jeandle.check_klass_subtype
; CHECK-NEXT:   ret i1 %r

!java-method-compilation = !{}
