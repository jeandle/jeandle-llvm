; RUN: opt -S -passes="type-check-elimination" -jeandle-vm-callback-log=%S/Inputs/interface-exclusion-kept.cblog %s 2>&1 | FileCheck %s

; A failed interface check is real information even when the positive klass is
; known: a class matching the klass may or may not implement the interface.
; The exclusion of interface 5 must survive normalization and fold the second
; instanceof-5 to false. Contrast: a failed CLASS check unrelated to the known
; klass stays foldable through areKlassesIncompatible.

declare i1 @jeandle.check_instanceof(ptr addrspace(0), ptr addrspace(1) nonnull)

define i1 @iface_exclusion_kept(ptr addrspace(1) "java-klass"="1" %obj) gc "hotspotgc" {
entry:
  %c = call i1 @jeandle.check_instanceof(ptr addrspace(0) inttoptr (i64 5 to ptr addrspace(0)), ptr addrspace(1) nonnull %obj)
  br i1 %c, label %yes, label %no
yes:
  ret i1 true
no:
  ; CHECK-LABEL: @iface_exclusion_kept(
  ; The check on 5 just failed: this object does not implement 5.
  ; CHECK: no:
  ; CHECK-NEXT: ret i1 false
  %r = call i1 @jeandle.check_instanceof(ptr addrspace(0) inttoptr (i64 5 to ptr addrspace(0)), ptr addrspace(1) nonnull %obj)
  ret i1 %r
}

; The same exclusion does not leak to a different interface: nothing is known
; about interface 6, so that probe stays live.
define i1 @other_iface_unaffected(ptr addrspace(1) "java-klass"="1" %obj) gc "hotspotgc" {
entry:
  %c = call i1 @jeandle.check_instanceof(ptr addrspace(0) inttoptr (i64 5 to ptr addrspace(0)), ptr addrspace(1) nonnull %obj)
  br i1 %c, label %yes, label %no
yes:
  ret i1 true
no:
  ; CHECK-LABEL: @other_iface_unaffected(
  ; CHECK: no:
  ; CHECK-NEXT: %r = call i1 @jeandle.check_instanceof
  ; CHECK-NEXT: ret i1 %r
  %r = call i1 @jeandle.check_instanceof(ptr addrspace(0) inttoptr (i64 6 to ptr addrspace(0)), ptr addrspace(1) nonnull %obj)
  ret i1 %r
}

; A class exclusion not below the known klass is dropped by normalization as
; already impossible — and the fold happens through the positive type instead
; (a Dog is never a Cat), so the probe folds false either way.
define i1 @class_exclusion_folded_via_klass(ptr addrspace(1) "java-klass"="3" %obj) gc "hotspotgc" {
entry:
  %c = call i1 @jeandle.check_instanceof(ptr addrspace(0) inttoptr (i64 4 to ptr addrspace(0)), ptr addrspace(1) nonnull %obj)
  br i1 %c, label %yes, label %no
yes:
  ret i1 true
no:
  ; CHECK-LABEL: @class_exclusion_folded_via_klass(
  ; CHECK: no:
  ; CHECK-NEXT: ret i1 false
  %r = call i1 @jeandle.check_instanceof(ptr addrspace(0) inttoptr (i64 4 to ptr addrspace(0)), ptr addrspace(1) nonnull %obj)
  ret i1 %r
}

!java-method-compilation = !{}
