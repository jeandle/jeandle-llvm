; RUN: opt -S -passes="expand-narrow-oop-cast" %s 2>&1 | FileCheck %s

; Regression test for the LLVM "Cannot emit physreg copy instruction" crash on
; X86 when compiling (compressed-oop) Java null into a narrow-oop field.
;
; Background: encoding a null Java heap oop (AS1) into a narrow oop (AS3) via
; CreateAddrSpaceCast yields a *constant* addrspacecast expression
;   addrspacecast (ptr addrspace(1) null to ptr addrspace(3))
; rather than an AddrSpaceCastInst.

target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-n32:64-S32-Fn32-p3:32:32:32"

define ptr addrspace(3) @encode_null_select(i1 %cond, ptr addrspace(3) %nonnull) #0 gc "hotspotgc" {
entry:
  ; The select operand is a *constant* addrspacecast of a null AS1 oop to AS3.
  ; After the pass it must be a direct ptr addrspace(3) null.
  %r = select i1 %cond,
               ptr addrspace(3) %nonnull,
               ptr addrspace(3) addrspacecast (ptr addrspace(1) null to ptr addrspace(3))
  ret ptr addrspace(3) %r
}

define ptr addrspace(3) @encode_null_direct() #0 gc "hotspotgc" {
entry:
  ; A standalone null constant addrspacecast of AS1 -> AS3 used as the return
  ; value (operand position again). Must fold to ptr addrspace(3) null.
  ret ptr addrspace(3) addrspacecast (ptr addrspace(1) null to ptr addrspace(3))
}

define ptr addrspace(1) @decode_null_direct() #0 gc "hotspotgc" {
entry:
  ; The decode direction (AS3 null -> AS1) must also fold to ptr addrspace(1) null.
  ret ptr addrspace(1) addrspacecast (ptr addrspace(3) null to ptr addrspace(1))
}

; CHECK-LABEL: define ptr addrspace(3) @encode_null_select(
; CHECK-NOT:    addrspacecast
; CHECK:        select i1 %cond, ptr addrspace(3) %nonnull, ptr addrspace(3) null
; CHECK-NOT:    addrspacecast
; CHECK-LABEL: define ptr addrspace(3) @encode_null_direct(
; CHECK-NOT:    addrspacecast
; CHECK:        ret ptr addrspace(3) null
; CHECK-LABEL: define ptr addrspace(1) @decode_null_direct(
; CHECK-NOT:    addrspacecast
; CHECK:        ret ptr addrspace(1) null

attributes #0 = { "java-method"="0" "use-compressed-oops" }

!java-method-compilation = !{}
