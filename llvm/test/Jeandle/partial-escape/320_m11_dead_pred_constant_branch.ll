; RUN: opt -S -passes="simplifycfg,require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; A constant-condition branch's dead arm contributes nothing to
; downstream merges / PHI fan-in. Without cleanup, processing the
; unreachable arm's sink call would materialize the virtual (because sink
; is an opaque escape consumer), preventing alloc elimination. The
; pre-PEA SimplifyCFG pass in buildJeandlePipeline prunes the dead arm
; before PEA sees the IR, so PEA processes only the live path and the
; virtual stays eliminable. The same upstream cleanup is invoked here
; from the RUN line.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(ptr addrspace(1))
declare void @use(i32)
declare i32 @__gxx_personality_v0(...)

define void @test_dead_pred_const(i32 %x)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %prep unwind label %u
prep:
  %s = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  store atomic i32 7, ptr addrspace(1) %s unordered, align 4
  ; Constant condition: only %live executes.
  br i1 false, label %dead, label %live
dead:
  ; This sink would normally escape %o; PEA must NOT materialize on this
  ; statically-unreachable path.
  call void @sink(ptr addrspace(1) %o)
  br label %fast
live:
  %v = load atomic i32, ptr addrspace(1) %s unordered, align 4
  call void @use(i32 %v)
  br label %fast
fast:
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; The alloc and stores/loads on the live path are fully eliminated; the
; sink call on the dead arm is gone too (pruned by SimplifyCFG before PEA
; runs).
; CHECK-LABEL: define void @test_dead_pred_const
; CHECK-NOT: jeandle.new_instance
; CHECK-NOT: store atomic
; CHECK-NOT: load atomic
; CHECK-NOT: call void @sink
; CHECK: call void @use(i32 7)

!java-method-compilation = !{}
