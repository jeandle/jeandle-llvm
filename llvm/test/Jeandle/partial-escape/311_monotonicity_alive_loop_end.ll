; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Monotonicity guard on alive loop ends. When the loop fixpoint
; iterates over a structurally non-trivial loop, the per-iteration
; BlockExits map for any loop block that has produced exit state on at
; least one iter MUST continue to produce exit state on every subsequent
; iter. Without the guard, a transient drop (e.g. an iter that bails on a
; merge before completing snapshotExitState for a tail block) would cause
; the convergence check to report inequivalence forever and the fixpoint
; would escalate to MATERIALIZE_ALL, materializing every virtual at the
; preheader.
;
; This test exercises a loop with a side-branch ("late") fed by an in-loop
; condition. The loop has a body alloc whose field is read on every path
; — including the side branch — and the fixpoint must converge cleanly
; without the side branch's exit state ever disappearing once it has been
; recorded. The alloc must be virtualised (no surviving new_instance).

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @use(i32)
declare i32 @__gxx_personality_v0(...)

define void @test_monotonicity_alive_loop_end(i32 %n, i32 %m)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  br label %loop
loop:
  %i = phi i32 [ 0, %entry ], [ %i1, %merge ]
  %cc = icmp slt i32 %i, %n
  br i1 %cc, label %body, label %exit
body:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 33333 to ptr), i32 16, i1 false)
       to label %st unwind label %u
st:
  %s = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  store atomic i32 %i, ptr addrspace(1) %s unordered, align 4
  %cm = icmp slt i32 %i, %m
  br i1 %cm, label %late, label %fast
late:
  %vl = load atomic i32, ptr addrspace(1) %s unordered, align 4
  call void @use(i32 %vl)
  br label %merge
fast:
  %vf = load atomic i32, ptr addrspace(1) %s unordered, align 4
  call void @use(i32 %vf)
  br label %merge
merge:
  %i1 = add i32 %i, 1
  br label %loop
exit:
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; Both paths' loads fold to the stored counter %i; the body-local alloc is
; gone. The "late" path's exit-state contribution to the fixpoint must
; have been monotonically preserved across iters.
; CHECK-LABEL: define void @test_monotonicity_alive_loop_end
; CHECK-NOT: jeandle.new_instance
; CHECK-NOT: load atomic
; CHECK: call void @use(i32 %i)
; CHECK: call void @use(i32 %i)

!java-method-compilation = !{}
