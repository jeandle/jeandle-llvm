; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; A self-referencing PHI in a loop header.
; processBlockPhis handles the loop PHI via its existing fixpoint
; logic; downstream consumers of the PHI may query resolveVirtualRef,
; which encounters the PHI's self-incoming and must terminate via the
; on-stack Visited check rather than infinite-recursing.
;
; The expected outcome: no analyzer crash, and — since a not-yet-visited
; back-edge incoming is treated as unknown rather than as a divergence —
; the iter-0 header merge takes Case B (the PHI aliases the VO), the VO
; stays virtual across the loop, and the allocation is fully eliminated.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @use(i32)
declare i32 @__gxx_personality_v0(...)

define void @test_cycle(i32 %n, i1 %c)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %ph unwind label %u
ph:
  br label %loop
loop:
  ; Self-referencing PHI: incoming from preheader is %o, incoming from
  ; back-edge is the PHI itself.
  %phi = phi ptr addrspace(1) [ %o, %ph ], [ %phi, %loop ]
  ; A consumer that queries resolveVirtualRef on %phi: the icmp eq
  ; against %o. Without on-stack cycle detection in
  ; resolveVirtualRef, the PHI->PHI back-edge would infinite-recurse.
  %eq = icmp eq ptr addrspace(1) %phi, %o
  br i1 %c, label %loop, label %exit
exit:
  br i1 %eq, label %same, label %diff
same:
  call void @use(i32 1)
  ret void
diff:
  call void @use(i32 -1)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; No crash, and the loop-carried VO is fully virtualized: the allocation
; is eliminated, the Case-B PHI is gone, and the identity icmp folds to
; true so only the %same arm survives.
; CHECK-LABEL: define void @test_cycle
; CHECK-NOT: call hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK: call void @use(i32 1)
; CHECK-NOT: call void @use(i32 -1)

!java-method-compilation = !{}
