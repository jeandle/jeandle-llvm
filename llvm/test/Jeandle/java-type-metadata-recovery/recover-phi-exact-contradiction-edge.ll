; RUN: opt -S -passes="recover-type-info" -jeandle-vm-callback-log=%S/Inputs/recover-phi-exact-contradiction-edge.cblog %s 2>&1 | FileCheck %s

; An exact-typed value (%obj is exactly klass 5, Cat) checked against an
; unrelated klass (7, Dog): the true edge is provably dead — no value can be
; both exactly 5 and a 7. The contradiction must not poison the PHI: with the
; exact claim kept, the PHI is Known(5) and the dependent load recovers the
; field type at offset 16.

declare i1 @jeandle.check_instanceof(ptr addrspace(0), ptr addrspace(1) nonnull)

define void @test(ptr addrspace(1) %p0) #0 gc "hotspotgc" {
entry:
  %obj = load ptr addrspace(1), ptr addrspace(1) %p0, !java-klass !0, !java-klass-exact !1
  %chk = call i1 @jeandle.check_instanceof(ptr addrspace(0) inttoptr (i64 7 to ptr addrspace(0)), ptr addrspace(1) nonnull %obj)
  br i1 %chk, label %t, label %f

t:
  br label %merge

f:
  br label %merge

merge:
  %p = phi ptr addrspace(1) [ %obj, %t ], [ %obj, %f ]
  %addr = getelementptr i8, ptr addrspace(1) %p, i64 16
  %v = load ptr addrspace(1), ptr addrspace(1) %addr
  ret void
}

; CHECK: %v = load ptr addrspace(1), ptr addrspace(1) %addr{{.*}}, !java-klass ![[K:[0-9]+]]
; CHECK: ![[K]] = !{i64 30}

attributes #0 = { "java-method"="0" }

!java-method-compilation = !{}
!0 = !{i64 5}
!1 = !{}
