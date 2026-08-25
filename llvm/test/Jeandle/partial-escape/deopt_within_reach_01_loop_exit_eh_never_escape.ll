; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; TODO(deopt-within-reach): a loop-local VO that never escapes, in a loop whose
; exit lands on a NON-pure-resume EH-pad (here a 1-clause `catch null` landingpad
; that only resumes). The EH handler does not observe the VO (exception unwind
; runs the handler with real state, but the handler only resumes; and PEA folds
; any handler field access via the unwind-edge virtual-state propagation). So
; the VO must stay NeverEscapes and its allocation be eliminated. Before the
; fix, processLoopExit conservatively force-materialized EVERY still-virtual VO
; at such an exit, so the allocation survived (over-conservative).

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare i32 @__gxx_personality_v0(...)

define void @test_deopt_within_reach_loop_exit_eh_never_escape(i32 %n) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  br label %loop
loop:
  %i = phi i32 [ 0, %entry ], [ %i1, %cont ]
  %c = icmp slt i32 %i, %n
  br i1 %c, label %body, label %exit
body:
  ; loop-local VO, observed ONLY inside the loop (field store consumed by the
  ; loop-carried count). NeverEscapes.
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
          ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %cont unwind label %u
cont:
  %s = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  store atomic i32 %i, ptr addrspace(1) %s unordered, align 4
  %i1 = add i32 %i, 1
  br label %loop
exit:
  ret void
u:
  ; NON-pure-resume EH-pad: a 1-clause landingpad (catch null) that only resumes.
  ; getNumClauses()==1 => isPureResumeCleanup carve-out does NOT apply.
  %lp = landingpad { ptr, i32 } catch ptr null
  resume { ptr, i32 } %lp
}

; CHECK-LABEL: define void @test_deopt_within_reach_loop_exit_eh_never_escape
; The loop-local allocation must be eliminated (NeverEscapes):
; CHECK-NOT: jeandle.new_instance
; CHECK: ret void

!java-method-compilation = !{}
