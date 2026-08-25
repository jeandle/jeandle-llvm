; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Companion to 401: guards that moving the identicalExitData fast-path INTO the
; merge do/while did NOT silently kill the optimization. Here both predecessors
; are genuinely byte-identical at the merge (the object stays virtual with the
; same field on both arms; nothing escapes), so the fast path fires and the
; merge installs preds[0]'s state directly — NO ptr addrspace(1) PHI and NO
; materialization. The original allocation is eliminated (the object never
; escapes), and the sink receives the folded field value.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(i32)
declare i32 @__gxx_personality_v0(...)

define void @test_identical_states_fast_path(i1 %c) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %branch unwind label %u
branch:
  br i1 %c, label %left, label %right
left:
  br label %merge
right:
  br label %merge
merge:
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; The object never escapes, so the allocation is eliminated and no
; materialization or PHI is emitted.
; CHECK-LABEL: define void @test_identical_states_fast_path
; CHECK-NOT: @jeandle.new_instance
; CHECK-NOT: phi ptr addrspace(1)
; CHECK: ret void

!java-method-compilation = !{}
