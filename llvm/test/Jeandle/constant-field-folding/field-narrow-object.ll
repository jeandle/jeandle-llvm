; RUN: opt -S -passes="constant-field-folding" -jeandle-vm-callback-log=%S/Inputs/field-narrow-object.cblog %s 2>&1 | FileCheck %s

; A constant narrow-oop (compressed) field read followed by a decode cast to
; the wide heap address space. The decode cast is eliminated at fold time and
; replaced by the wide constant (a load of the @oop_handle global), so no
; addrspacecast survives -- downstream value-dependent uses (here the return)
; observe the wide constant directly, which lets later SCCP/InstSimplify fold.

@oop_handle_Root_0 = external global ptr addrspace(1)

define ptr addrspace(1) @test() gc "hotspotgc" {
entry:
  %base = load ptr addrspace(1), ptr @oop_handle_Root_0
  %addr = getelementptr i8, ptr addrspace(1) %base, i64 16
  %narrow = load ptr addrspace(3), ptr addrspace(1) %addr
  %wide = addrspacecast ptr addrspace(3) %narrow to ptr addrspace(1)
  ret ptr addrspace(1) %wide
}

; CHECK: @oop_handle_Child_1 = external dso_local global ptr addrspace(1)
; CHECK: %folded.oop = load ptr addrspace(1), ptr @oop_handle_Child_1
; CHECK-NOT: addrspacecast
; CHECK: ret ptr addrspace(1) %folded.oop

!java-method-compilation = !{}
