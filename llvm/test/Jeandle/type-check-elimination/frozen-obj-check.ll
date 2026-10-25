; RUN: opt -S -passes="type-check-elimination" -jeandle-vm-callback-log=%S/Inputs/frozen-obj-check.cblog %s 2>&1 | FileCheck %s

; A check whose object operand is a freeze of the queried oop traces to that
; oop: the canonicalization on both sides must be the same definedness-aware
; strip (freeze of a noundef argument is transparent), so the edge guard
; proven for the frozen use also sharpens queries about the original oop.

declare i1 @jeandle.check_instanceof(ptr addrspace(0), ptr addrspace(1) nonnull)

define i1 @test(ptr addrspace(1) noundef %obj) gc "hotspotgc" {
entry:
  %frz = freeze ptr addrspace(1) %obj
  %c = call i1 @jeandle.check_instanceof(ptr addrspace(0) inttoptr (i64 20 to ptr addrspace(0)), ptr addrspace(1) nonnull %frz)
  br i1 %c, label %pass, label %fail

pass:
  %r = call i1 @jeandle.check_instanceof(ptr addrspace(0) inttoptr (i64 20 to ptr addrspace(0)), ptr addrspace(1) nonnull %obj)
  ret i1 %r

fail:
  ret i1 false
}

; CHECK: pass:
; CHECK-NEXT:   ret i1 true

!java-method-compilation = !{}
