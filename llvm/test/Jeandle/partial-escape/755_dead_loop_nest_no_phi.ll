; RUN: opt -S -verify-each \
; RUN:   -passes="require<partial-escape-analysis>,partial-escape-transform" \
; RUN:   %s | FileCheck %s

; Dead-loop-nest variants that must NOT synthesize a field PHI:
; - agree: the live merge preds agree on the field value, so no PHI is needed;
;   the dead nest is still published dead and removed by cleanup.
; - escape_inside: the receiver's only escape use sits inside the dead nest;
;   the commit-side surviving-use audit whitelists uses in dead-published
;   blocks, so the allocation is still eliminated.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @escape(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define i32 @dead_loop_nest_agree(i1 %choose, i32 %limit)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 75501 to ptr), i32 24, i1 false)
      to label %guard unwind label %alloc.unwind

guard:
  %is.null = icmp eq ptr addrspace(1) %o, null
  br i1 %is.null, label %preheader, label %live.dispatch

preheader:
  br label %loop.header

loop.header:
  %i = phi i32 [ 0, %preheader ], [ %inc, %latch ]
  br label %latch

latch:
  %inc = add i32 %i, 1
  %more = icmp ult i32 %inc, %limit
  br i1 %more, label %loop.header, label %loop.exit

loop.exit:
  br label %merge

live.dispatch:
  br i1 %choose, label %left, label %right

left:
  %left.field = getelementptr inbounds i8, ptr addrspace(1) %o, i64 16
  store atomic i32 42, ptr addrspace(1) %left.field unordered, align 4
  br label %merge

right:
  %right.field = getelementptr inbounds i8, ptr addrspace(1) %o, i64 16
  store atomic i32 42, ptr addrspace(1) %right.field unordered, align 4
  br label %merge

merge:
  %reload = getelementptr inbounds i8, ptr addrspace(1) %o, i64 16
  %value = load atomic i32, ptr addrspace(1) %reload unordered, align 4
  ret i32 %value

alloc.unwind:
  %ex = landingpad i64 cleanup
  resume i64 %ex
}

; CHECK-LABEL: define i32 @dead_loop_nest_agree(
; CHECK-NOT: @jeandle.new_instance
; CHECK-NOT: preheader:
; CHECK-NOT: loop.header:
; CHECK-NOT: latch:
; CHECK-NOT: loop.exit:
; CHECK-NOT: pea.field.phi
; CHECK-NOT: poison
; CHECK: ret i32 42

define i32 @dead_loop_escape_inside(i1 %choose, i32 %limit)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 75502 to ptr), i32 24, i1 false)
      to label %guard unwind label %alloc.unwind

guard:
  %is.null = icmp eq ptr addrspace(1) %o, null
  br i1 %is.null, label %preheader, label %live.dispatch

preheader:
  br label %loop.header

loop.header:
  %i = phi i32 [ 0, %preheader ], [ %inc, %latch ]
  br label %latch

latch:
  call void @escape(ptr addrspace(1) %o)
  %inc = add i32 %i, 1
  %more = icmp ult i32 %inc, %limit
  br i1 %more, label %loop.header, label %loop.exit

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

; The escape call is inside the dead nest: it never executes at runtime, so
; the receiver is still NeverEscapes and the allocation is eliminated.
; CHECK-LABEL: define i32 @dead_loop_escape_inside(
; CHECK-NOT: @jeandle.new_instance
; CHECK-NOT: @escape
; CHECK-NOT: preheader:
; CHECK-NOT: loop.header:
; CHECK-NOT: latch:
; CHECK-NOT: loop.exit:
; CHECK: merge:
; CHECK-NEXT: %pea.field.phi = phi i32 [ 62, %right ], [ 61, %left ]
; CHECK-NEXT: ret i32 %pea.field.phi
; CHECK-NOT: poison

!java-method-compilation = !{}
