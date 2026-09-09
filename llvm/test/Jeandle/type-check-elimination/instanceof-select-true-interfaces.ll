; RUN: opt -S -passes="type-check-elimination" -jeandle-vm-callback-log=%S/Inputs/instanceof-select-true-interfaces.cblog %s 2>&1 | FileCheck %s

; Regression: a select with two non-constant check_instanceof arms merges its
; arms with OneOf semantics. The true branch's interface set must come from
; the arms' TrueInterfaces (klass 22 implements interface 33); assigning the
; false-side interfaces into the true side clobbers {33} to {} and the
; interface check in %pass stops folding.

declare i1 @jeandle.check_instanceof(ptr addrspace(0), ptr addrspace(1) nonnull)

define i1 @test(ptr addrspace(1) "java-klass"="1" %obj, i1 %s) gc "hotspotgc" {
entry:
  %ca = call i1 @jeandle.check_instanceof(ptr addrspace(0) inttoptr (i64 22 to ptr addrspace(0)), ptr addrspace(1) nonnull %obj)
  %cb = call i1 @jeandle.check_instanceof(ptr addrspace(0) inttoptr (i64 22 to ptr addrspace(0)), ptr addrspace(1) nonnull %obj)
  %sel = select i1 %s, i1 %ca, i1 %cb
  br i1 %sel, label %pass, label %fail

pass:
  %r = call i1 @jeandle.check_instanceof(ptr addrspace(0) inttoptr (i64 33 to ptr addrspace(0)), ptr addrspace(1) nonnull %obj)
  ret i1 %r

fail:
  ret i1 false
}

; The two checks in entry are preserved (no information at their own sites),
; but the interface check in %pass folds: on the true edge of %sel, %obj is
; known to be klass 22, whose interface set includes 33.
; CHECK: entry:
; CHECK:   %ca = call i1 @jeandle.check_instanceof
; CHECK:   %cb = call i1 @jeandle.check_instanceof
; CHECK: pass:
; CHECK-NEXT:   ret i1 true

!java-method-compilation = !{}
