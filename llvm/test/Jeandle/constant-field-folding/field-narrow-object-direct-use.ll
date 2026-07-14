; RUN: opt -S -passes="constant-field-folding" -jeandle-vm-callback-log=%S/Inputs/field-narrow-object-direct-use.cblog %s 2>&1 | FileCheck %s

; A constant narrow-oop field whose load has NO decode-cast user — the narrow
; value is consumed directly (returned). This is the case the previous
; (restrictive) implementation bailed on; it must now fold and materialise the
; constant in the narrow address space regardless of the user shape.

@oop_handle_Root_0 = external global ptr addrspace(1)

define ptr addrspace(3) @test() gc "hotspotgc" {
entry:
  %base = load ptr addrspace(1), ptr @oop_handle_Root_0
  %addr = getelementptr i8, ptr addrspace(1) %base, i64 16
  %narrow = load ptr addrspace(3), ptr addrspace(1) %addr
  ret ptr addrspace(3) %narrow
}

; CHECK: @oop_handle_Child_1 = external dso_local global ptr addrspace(1)
; CHECK: %folded.oop = load ptr addrspace(1), ptr @oop_handle_Child_1
; CHECK: %folded.narrow.oop = addrspacecast ptr addrspace(1) %folded.oop to ptr addrspace(3)
; CHECK: ret ptr addrspace(3) %folded.narrow.oop

!java-method-compilation = !{}
