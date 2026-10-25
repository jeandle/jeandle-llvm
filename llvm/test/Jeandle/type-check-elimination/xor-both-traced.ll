; RUN: opt -S -passes="type-check-elimination" -jeandle-vm-callback-log=%S/Inputs/xor-both-traced.cblog %s 2>&1 | FileCheck %s

; xor of two traced checks: true ⟺ exactly one operand true. With B <: A
; (klass 21 <: klass 20), the true side of `xor (instanceof A) (instanceof B)`
; joins "A without B" with the dead "B without A" arm and settles on a
; Known(A), so the dominating instanceof A in %pass folds to true.

declare i1 @jeandle.check_instanceof(ptr addrspace(0), ptr addrspace(1) nonnull)

define i1 @test(ptr addrspace(1) %obj) gc "hotspotgc" {
entry:
  %a = call i1 @jeandle.check_instanceof(ptr addrspace(0) inttoptr (i64 20 to ptr addrspace(0)), ptr addrspace(1) nonnull %obj)
  %b = call i1 @jeandle.check_instanceof(ptr addrspace(0) inttoptr (i64 21 to ptr addrspace(0)), ptr addrspace(1) nonnull %obj)
  %x = xor i1 %a, %b
  br i1 %x, label %pass, label %fail

pass:
  %r = call i1 @jeandle.check_instanceof(ptr addrspace(0) inttoptr (i64 20 to ptr addrspace(0)), ptr addrspace(1) nonnull %obj)
  ret i1 %r

fail:
  ret i1 false
}

; CHECK: pass:
; CHECK-NEXT:   ret i1 true

!java-method-compilation = !{}
