; RUN: opt -S -verify-each \
; RUN:   -passes="require<partial-escape-analysis>,partial-escape-transform" \
; RUN:   %s | FileCheck %s

; No-preheader variant of 752_dead_loop_nest_field_phi.ll: the header has two
; forward predecessors (%fwd_a, %fwd_b) and one latch, so getLoopPreheader()
; returns nullptr and processLoop takes the no-preheader path. Both forward
; edges are PEA-proven dead (null checks on the still-virtual receiver fold),
; so the whole nest is runtime-unreachable: the no-preheader guard must
; publish dead exits for all loop blocks instead of running a body walk whose
; header would defer at the entry gate. The merge then sees a Dead (not
; eternally Unseen) loop predecessor and pads its slot with poison, which the
; final cleanup removes together with the dead nest.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare i32 @__gxx_personality_v0(...)

define i32 @dead_loop_nest_no_preheader(i1 %choose, i32 %n)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 75301 to ptr), i32 24, i1 false)
      to label %guard unwind label %alloc.unwind

guard:
  %is.null = icmp eq ptr addrspace(1) %o, null
  br i1 %is.null, label %fwd_a, label %d2

d2:
  %not.null = icmp ne ptr addrspace(1) %o, null
  br i1 %not.null, label %live.dispatch, label %fwd_b

fwd_a:
  br label %hdr

fwd_b:
  br label %hdr

hdr:
  %i = phi i32 [ 0, %fwd_a ], [ 0, %fwd_b ], [ %i1, %latch ]
  %c = icmp slt i32 %i, %n
  br i1 %c, label %body, label %loop.exit

body:
  br label %latch

latch:
  %i1 = add i32 %i, 1
  br label %hdr

loop.exit:
  br label %merge

live.dispatch:
  br i1 %choose, label %left, label %right

left:
  %left.field = getelementptr inbounds i8, ptr addrspace(1) %o, i64 16
  store atomic i32 61, ptr addrspace(1) %left.field unordered, align 4
  br label %merge

right:
  %right.field = getelementptr inbounds i8, ptr addrspace(1) %o, i64 16
  store atomic i32 62, ptr addrspace(1) %right.field unordered, align 4
  br label %merge

merge:
  %reload = getelementptr inbounds i8, ptr addrspace(1) %o, i64 16
  %value = load atomic i32, ptr addrspace(1) %reload unordered, align 4
  ret i32 %value

alloc.unwind:
  %ex = landingpad i64 cleanup
  resume i64 %ex
}

; CHECK-LABEL: define i32 @dead_loop_nest_no_preheader(
; CHECK-NOT: @jeandle.new_instance
; CHECK-NOT: fwd_a:
; CHECK-NOT: fwd_b:
; CHECK-NOT: hdr:
; CHECK-NOT: body:
; CHECK-NOT: latch:
; CHECK-NOT: loop.exit:
; CHECK-NOT: alloc.unwind:
; CHECK: merge:
; CHECK-NEXT: %pea.field.phi = phi i32 [ 62, %right ], [ 61, %left ]
; CHECK-NEXT: ret i32 %pea.field.phi
; CHECK-NOT: poison

!java-method-compilation = !{}
