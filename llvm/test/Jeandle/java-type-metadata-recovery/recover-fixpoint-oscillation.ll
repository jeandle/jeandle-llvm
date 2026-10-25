; RUN: opt -S -passes="recover-type-info" -debug-only=recover-type-info -jeandle-vm-callback-log=%S/Inputs/recover-fixpoint-oscillation.cblog %s 2>&1 | FileCheck %s
; REQUIRES: asserts

; A loop-carried PHI whose declared-klass arm (klass 3) contradicts the
; context type proven by the dominating check (klass 4): typeIntersect of two
; unrelated non-exact klasses has no representable result, so the typed load
; used to fall to Bottom, the PHI followed, the load was then rescued from
; Bottom by the context type, and the two values flipped forever — the round
; cap was the only reason this terminated. The fixpoint must converge on its
; own: the contradiction keeps the lattice side (dead-path intersection, same
; rule as JavaType's SCC keep-previous-klass), so %L stably recovers klass 3
; (the self-referential field of klass 3 at offset 16).

declare i1 @jeandle.check_instanceof(ptr addrspace(0), ptr addrspace(1) nonnull)

define void @test(ptr addrspace(1) "java-klass"="3" %x) #0 gc "hotspotgc" {
entry:
  br label %loop
loop:
  %p = phi ptr addrspace(1) [ %x, %entry ], [ %L, %body ]
  %check = call i1 @jeandle.check_instanceof(ptr addrspace(0) inttoptr (i64 4 to ptr addrspace(0)), ptr addrspace(1) nonnull %p)
  br i1 %check, label %body, label %exit
body:
  %addr = getelementptr i8, ptr addrspace(1) %p, i64 16
  %L = load ptr addrspace(1), ptr addrspace(1) %addr
  br label %loop
exit:
  ret void
}

; The fixpoint must converge before the round cap.
; CHECK-NOT: hit round cap
; CHECK: %L = load ptr addrspace(1), ptr addrspace(1) %addr{{.*}}, !java-klass ![[K:[0-9]+]]
; CHECK: ![[K]] = !{i64 3}

attributes #0 = { "java-method"="0" }

!java-method-compilation = !{}
