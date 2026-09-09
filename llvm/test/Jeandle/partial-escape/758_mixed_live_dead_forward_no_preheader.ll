; RUN: opt -S -verify-each \
; RUN:   -passes="require<partial-escape-analysis>,partial-escape-transform" \
; RUN:   %s | FileCheck %s

; No-preheader loop with MIXED forward edges: %fwd_a is Live, %fwd_b is
; PEA-proven dead. The no-preheader guard must keep the ordinary has-Live
; behavior: bail the header-virtual VO to ineligible (the alloc and the @sink
; call survive) and run the single body walk — never publish the nest dead.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @mixed_live_dead_forward_no_preheader(i1 %p, i32 %n)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 75801 to ptr), i32 16, i1 false)
      to label %dispatch unwind label %u

dispatch:
  br i1 %p, label %fwd_a, label %fold.guard

fold.guard:
  %is.null = icmp eq ptr addrspace(1) %o, null
  br i1 %is.null, label %fwd_b, label %fwd_a

fwd_a:
  br label %hdr

fwd_b:
  br label %hdr

hdr:
  %i = phi i32 [ 0, %fwd_a ], [ 0, %fwd_b ], [ %i1, %latch ]
  %c = icmp slt i32 %i, %n
  br i1 %c, label %body, label %exit

body:
  call void @sink(ptr addrspace(1) %o)
  br label %latch

latch:
  %i1 = add i32 %i, 1
  br label %hdr

exit:
  ret void

u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @mixed_live_dead_forward_no_preheader
; CHECK: invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; The VO bail revokes the %is.null fold, so %fwd_b conservatively survives
; and the header PHI keeps all three structural incomings.
; CHECK: fwd_b:
; CHECK: hdr:
; CHECK-NEXT: %i = phi i32 [ 0, %fwd_a ], [ 0, %fwd_b ], [ %i1, %latch ]
; CHECK: call void @sink(ptr addrspace(1) %o)
; CHECK: exit:
; CHECK: ret void

!java-method-compilation = !{}
