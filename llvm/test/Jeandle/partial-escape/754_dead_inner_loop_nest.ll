; RUN: opt -S -verify-each \
; RUN:   -passes="require<partial-escape-analysis>,partial-escape-transform" \
; RUN:   %s | FileCheck %s

; Nested variant: the outer loop is live, but the inner loop's only forward
; edge is PEA-proven dead inside the outer body. The nested processLoop
; dispatch must publish dead exits for the inner nest on every outer body
; pass; the in-outer-body merge (%inmerge) then treats the inner loop's exit
; predecessor as Dead (poison slot) instead of skipping it, and the outer
; fixpoint converges normally. Pre-fix the inner nest deferred at the entry
; gate, never published, and %inmerge's field PHI missed the inner predecessor
; incoming.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare i32 @__gxx_personality_v0(...)

define i32 @dead_inner_loop_nest(i1 %choose, i32 %limit)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 75401 to ptr), i32 24, i1 false)
      to label %outer.preheader unwind label %alloc.unwind

outer.preheader:
  br label %outer.header

outer.header:
  %j = phi i32 [ 0, %outer.preheader ], [ %jinc, %outer.latch ]
  br label %outer.body

outer.body:
  %is.null = icmp eq ptr addrspace(1) %o, null
  br i1 %is.null, label %inner.preheader, label %live.dispatch

inner.preheader:
  br label %inner.header

inner.header:
  %i = phi i32 [ 0, %inner.preheader ], [ %iinc, %inner.latch ]
  br label %inner.latch

inner.latch:
  %iinc = add i32 %i, 1
  %in.more = icmp ult i32 %iinc, %limit
  br i1 %in.more, label %inner.header, label %inmerge

live.dispatch:
  br i1 %choose, label %store.a, label %store.b

store.a:
  %a.field = getelementptr inbounds i8, ptr addrspace(1) %o, i64 16
  store atomic i32 11, ptr addrspace(1) %a.field unordered, align 4
  br label %inmerge

store.b:
  %b.field = getelementptr inbounds i8, ptr addrspace(1) %o, i64 16
  store atomic i32 22, ptr addrspace(1) %b.field unordered, align 4
  br label %inmerge

inmerge:
  br label %outer.latch

outer.latch:
  %jinc = add i32 %j, 1
  %out.more = icmp ult i32 %jinc, %limit
  br i1 %out.more, label %outer.header, label %outer.exit

outer.exit:
  %reload = getelementptr inbounds i8, ptr addrspace(1) %o, i64 16
  %value = load atomic i32, ptr addrspace(1) %reload unordered, align 4
  ret i32 %value

alloc.unwind:
  %ex = landingpad i64 cleanup
  resume i64 %ex
}

; CHECK-LABEL: define i32 @dead_inner_loop_nest(
; CHECK-NOT: @jeandle.new_instance
; CHECK-NOT: inner.preheader:
; CHECK-NOT: inner.header:
; CHECK-NOT: inner.latch:
; CHECK: outer.header:
; CHECK: inmerge:
; CHECK-NEXT: %pea.field.phi{{[0-9]*}} = phi i32 [ 22, %store.b ], [ 11, %store.a ]
; CHECK-NEXT: br label %outer.latch
; CHECK: outer.latch:
; CHECK: outer.exit:
; CHECK-NEXT: ret i32 %pea.field.phi{{[0-9]*}}
; CHECK-NOT: poison

!java-method-compilation = !{}
