; RUN: opt -S -passes="recover-type-info" -jeandle-vm-callback-log=%S/Inputs/recover-phi-incoming-edge-sharpened.cblog %s 2>&1 | FileCheck %s

; Per-incoming edge sharpening distributed into the lattice. %object_A carries
; metadata (klass 5, Animal) and arrives at the merge along the true edge of a
; check_instanceof proving Dog (klass 22, a subtype of 5). %object_B has no
; metadata but is recoverable through its own field chain (to klass 9, Beagle,
; a subtype of Dog), so the PHI-base context query stays poisoned and only the
; lattice can use the edge fact: the PHI's type must be meet(22, 9) = 22 (Dog)
; rather than meet(5, 9) = 5 (Animal), giving the dependent load the field
; type 31 instead of 30.

declare i1 @jeandle.check_instanceof(ptr addrspace(0), ptr addrspace(1) nonnull)

define void @test(i1 %c, ptr addrspace(1) "java-klass"="9" %p1, ptr addrspace(1) %p0) #0 gc "hotspotgc" {
entry:
  br i1 %c, label %path_A, label %path_B

path_A:
  %object_A = load ptr addrspace(1), ptr addrspace(1) %p0, !java-klass !0
  %is_dog = call i1 @jeandle.check_instanceof(ptr addrspace(0) inttoptr (i64 22 to ptr addrspace(0)), ptr addrspace(1) nonnull %object_A)
  br i1 %is_dog, label %path_merge, label %else

else:
  ret void

path_B:
  %addr1 = getelementptr i8, ptr addrspace(1) %p1, i64 16
  %object_B = load ptr addrspace(1), ptr addrspace(1) %addr1
  br label %path_merge

path_merge:
  %obj_phi = phi ptr addrspace(1) [ %object_A, %path_A ], [ %object_B, %path_B ]
  %addr = getelementptr i8, ptr addrspace(1) %obj_phi, i64 16
  %v = load ptr addrspace(1), ptr addrspace(1) %addr
  ret void
}

; %object_B is recovered through its own chain (field type 9).
; CHECK: %object_B = load ptr addrspace(1), ptr addrspace(1) %addr1{{.*}}, !java-klass ![[B:[0-9]+]]
; %v must use the edge-sharpened PHI type: field of Dog (22), not of Animal (5).
; CHECK: %v = load ptr addrspace(1), ptr addrspace(1) %addr{{.*}}, !java-klass ![[V:[0-9]+]]
; CHECK: ![[B]] = !{i64 9}
; CHECK: ![[V]] = !{i64 31}

attributes #0 = { "java-method"="0" }

!java-method-compilation = !{}
!0 = !{i64 5}
