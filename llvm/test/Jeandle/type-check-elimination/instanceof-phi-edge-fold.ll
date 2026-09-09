; RUN: opt -S -passes="type-check-elimination" -jeandle-vm-callback-log=%S/Inputs/instanceof-phi-edge-fold.cblog %s 2>&1 | FileCheck %s

; PHI incoming edge sharpening: %object_A arrives at the merge along the true
; edge of a check_instanceof proving it is klass 22 (Dog, a subtype of its
; declared klass 5). The other incoming %object_B is klass 9 (a subtype of
; Dog). Even though the merge has another predecessor (so no edge dominance
; over the merge block), the incoming value on that edge IS 22, so %phi's
; type is meet(22, 9) = 22 and the instanceof query on %phi must fold to
; true. The original check on %object_A must be preserved (it is a different
; value's check).

declare i1 @jeandle.check_instanceof(ptr addrspace(0), ptr addrspace(1) nonnull)

define i1 @test(i1 %c, ptr addrspace(1) %p0, ptr addrspace(1) %p1) #0 gc "hotspotgc" {
entry:
  br i1 %c, label %path_A, label %path_B

path_A:
  %object_A = load ptr addrspace(1), ptr addrspace(1) %p0, !java-klass !0
  %is_dog = call i1 @jeandle.check_instanceof(ptr addrspace(0) inttoptr (i64 22 to ptr addrspace(0)), ptr addrspace(1) nonnull %object_A)
  br i1 %is_dog, label %path_merge, label %else

else:
  ret i1 false

path_B:
  %object_B = load ptr addrspace(1), ptr addrspace(1) %p1, !java-klass !1
  br label %path_merge

path_merge:
  %obj_phi = phi ptr addrspace(1) [ %object_A, %path_A ], [ %object_B, %path_B ]
  %r = call i1 @jeandle.check_instanceof(ptr addrspace(0) inttoptr (i64 22 to ptr addrspace(0)), ptr addrspace(1) nonnull %obj_phi)
  ret i1 %r
}

; The original check on %object_A is preserved (Animal is not a subtype of
; Dog, but they are compatible).
; CHECK: %is_dog = call i1 @jeandle.check_instanceof
; else branch:
; CHECK: ret i1 false
; The instanceof on %phi folds: the merge block is left with just the phi.
; CHECK: %obj_phi = phi
; CHECK-NEXT: ret i1 true

attributes #0 = { "java-method"="0" }

!java-method-compilation = !{}
!0 = !{i64 5}
!1 = !{i64 9}
