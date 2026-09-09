; RUN: opt -S -verify-each -passes="partial-escape-iterative" \
; RUN:   -jeandle-pea-iterations=2 %s | FileCheck %s

; A virtual object is stored into a compressed-oop field of a virtual tuple.
; A virtual iterator selects one of the tuple's three AS3 fields inside a loop;
; the AS3 PHI is decoded once and consumed opaquely. Although the first abstract
; loop iteration selects field zero, a later runtime iteration selects %o, so
; %o must be materialized before that in-loop consumer. It is also consumed at
; exit to expose an incorrect late replay: skipping the AS3 PHI used to move
; %o's field initialization to the exit call.
;
; %dead is deliberately independent and never escapes. The tuple and iterator
; should also disappear. Fixing the compressed mixed PHI must not disable
; unrelated scalar replacement or the virtual iterator optimization.

target datalayout = "e-p:64:64-p1:64:64-p3:32:32"

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @consume(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @loop_mixed_narrow_phi_replay_order(ptr addrspace(1) %real0,
                                                ptr addrspace(1) %real1,
                                                i32 %value)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
           ptr inttoptr (i64 76501 to ptr), i32 16, i1 false)
       to label %alloc.tuple unwind label %unwind

alloc.tuple:
  %tuple = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
               ptr inttoptr (i64 76502 to ptr), i32 24, i1 false)
           to label %alloc.iter unwind label %unwind

alloc.iter:
  %iter = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
              ptr inttoptr (i64 76503 to ptr), i32 16, i1 false)
          to label %alloc.dead unwind label %unwind

alloc.dead:
  %dead = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
              ptr inttoptr (i64 76504 to ptr), i32 16, i1 false)
          to label %init unwind label %unwind

init:
  %slot = getelementptr inbounds i8, ptr addrspace(1) %o, i64 12
  store atomic i32 %value, ptr addrspace(1) %slot unordered, align 4

  %real0.narrow = addrspacecast ptr addrspace(1) %real0 to ptr addrspace(3)
  %tuple.0 = getelementptr inbounds i8, ptr addrspace(1) %tuple, i64 12
  store atomic ptr addrspace(3) %real0.narrow, ptr addrspace(1) %tuple.0
      unordered, align 4
  %real1.narrow = addrspacecast ptr addrspace(1) %real1 to ptr addrspace(3)
  %tuple.1 = getelementptr inbounds i8, ptr addrspace(1) %tuple, i64 16
  store atomic ptr addrspace(3) %real1.narrow, ptr addrspace(1) %tuple.1
      unordered, align 4
  %o.narrow = addrspacecast ptr addrspace(1) %o to ptr addrspace(3)
  %tuple.2 = getelementptr inbounds i8, ptr addrspace(1) %tuple, i64 20
  store atomic ptr addrspace(3) %o.narrow, ptr addrspace(1) %tuple.2
      unordered, align 4

  %dead.slot = getelementptr inbounds i8, ptr addrspace(1) %dead, i64 12
  store atomic i32 99, ptr addrspace(1) %dead.slot unordered, align 4
  %index.slot = getelementptr inbounds i8, ptr addrspace(1) %iter, i64 12
  store atomic i32 0, ptr addrspace(1) %index.slot unordered, align 4
  br label %header

header:
  %index = load atomic i32, ptr addrspace(1) %index.slot unordered, align 4
  %more = icmp slt i32 %index, 3
  br i1 %more, label %dispatch, label %exit

dispatch:
  switch i32 %index, label %arm0 [
    i32 1, label %arm1
    i32 2, label %virtual.arm
  ]

arm0:
  %v0 = load atomic ptr addrspace(3), ptr addrspace(1) %tuple.0
      unordered, align 4
  br label %merge

arm1:
  %v1 = load atomic ptr addrspace(3), ptr addrspace(1) %tuple.1
      unordered, align 4
  br label %merge

virtual.arm:
  %v2 = load atomic ptr addrspace(3), ptr addrspace(1) %tuple.2
      unordered, align 4
  br label %merge

merge:
  %selected.narrow = phi ptr addrspace(3) [ %v0, %arm0 ],
                                             [ %v1, %arm1 ],
                                             [ %v2, %virtual.arm ]
  %selected = addrspacecast ptr addrspace(3) %selected.narrow
      to ptr addrspace(1)
  call void @consume(ptr addrspace(1) %selected)
  %next = add i32 %index, 1
  store atomic i32 %next, ptr addrspace(1) %index.slot unordered, align 4
  br label %header

exit:
  call void @consume(ptr addrspace(1) %o)
  ret void

unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @loop_mixed_narrow_phi_replay_order(
; CHECK: %o = {{(call|invoke)}} hotspotcc ptr addrspace(1) @jeandle.new_instance(
; CHECK-NOT: ptr inttoptr (i64 76502 to ptr)
; CHECK-NOT: ptr inttoptr (i64 76503 to ptr)
; CHECK-NOT: ptr inttoptr (i64 76504 to ptr)
; CHECK: store atomic i32 %value
; CHECK: call void @consume(ptr addrspace(1) %{{.*}})
; CHECK-NOT: store atomic i32 %value
; CHECK: call void @consume(ptr addrspace(1) %o)

; All incoming arms of this AS3 PHI denote the same virtual object. This is
; Case B, so the compressed representation PHI remains a whole-object alias:
; both allocations and the PHI/decode/load chain can still disappear. This
; guards against fixing the mixed-identity case by conservatively materializing
; every compressed PHI.
define i32 @same_object_narrow_phi_stays_virtual(i1 %cond, i32 %value)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
           ptr inttoptr (i64 76511 to ptr), i32 16, i1 false)
       to label %alloc.holder unwind label %unwind

alloc.holder:
  %holder = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
                ptr inttoptr (i64 76512 to ptr), i32 20, i1 false)
            to label %init unwind label %unwind

init:
  %o.slot = getelementptr inbounds i8, ptr addrspace(1) %o, i64 12
  store atomic i32 %value, ptr addrspace(1) %o.slot unordered, align 4
  %o.narrow = addrspacecast ptr addrspace(1) %o to ptr addrspace(3)
  %holder.0 = getelementptr inbounds i8, ptr addrspace(1) %holder, i64 12
  store atomic ptr addrspace(3) %o.narrow, ptr addrspace(1) %holder.0
      unordered, align 4
  %holder.1 = getelementptr inbounds i8, ptr addrspace(1) %holder, i64 16
  store atomic ptr addrspace(3) %o.narrow, ptr addrspace(1) %holder.1
      unordered, align 4
  br i1 %cond, label %left, label %right

left:
  %left.ref = load atomic ptr addrspace(3), ptr addrspace(1) %holder.0
      unordered, align 4
  br label %merge

right:
  %right.ref = load atomic ptr addrspace(3), ptr addrspace(1) %holder.1
      unordered, align 4
  br label %merge

merge:
  %selected.narrow = phi ptr addrspace(3) [ %left.ref, %left ],
                                             [ %right.ref, %right ]
  %selected = addrspacecast ptr addrspace(3) %selected.narrow
      to ptr addrspace(1)
  %selected.slot = getelementptr inbounds i8, ptr addrspace(1) %selected, i64 12
  %result = load atomic i32, ptr addrspace(1) %selected.slot unordered, align 4
  ret i32 %result

unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define i32 @same_object_narrow_phi_stays_virtual(
; CHECK-NOT: @jeandle.new_instance
; CHECK: ret i32 %value

!java-method-compilation = !{}
