; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s -o %t
; RUN: FileCheck %s < %t
; RUN: not grep '!jeandle[.]pea[.]replay' %t

; Case-A with a folded arraylength invoke and a structured monitor region.
; Both normal paths leave the monitor in merge; the exceptional path leaves it
; in handler. Any replay caused by the pointer PHI must remain on its incoming
; edge, and every surviving enter must have the corresponding real exit.

declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32, i1, i1)
declare hotspotcc i32 @jeandle.arraylength(ptr addrspace(1) readonly)
declare hotspotcc void @jeandle.monitorenter_with_lightweight_lock(ptr addrspace(1), ptr) nounwind
declare hotspotcc void @jeandle.monitorexit_with_lightweight_lock(ptr addrspace(1), ptr) nounwind
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @casea_folded_invoke_term_locks(i1 %c) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %lo = alloca i64, align 8
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 12345 to ptr), i32 7, i32 44, i32 16, i32 1048576, i1 false, i1 false)
         to label %n unwind label %u
n:
  call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(ptr addrspace(1) %o, ptr %lo)
  br i1 %c, label %then, label %else
then:
  br label %merge
else:
  %len = invoke hotspotcc i32 @jeandle.arraylength(ptr addrspace(1) %o) to label %merge unwind label %handler
merge:
  %p = phi ptr addrspace(1) [ null, %then ], [ %o, %else ]
  call void @sink(ptr addrspace(1) %p)
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
      ptr addrspace(1) %o, ptr %lo)
  ret void
handler:
  %lp = landingpad i64 cleanup
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
      ptr addrspace(1) %o, ptr %lo)
  resume i64 %lp
u:
  %lpr = landingpad i64 cleanup
  resume i64 %lpr
}

!java-method-compilation = !{}

; CHECK-LABEL: define void @casea_folded_invoke_term_locks
; The folded arraylength invoke is erased.
; CHECK-NOT: @jeandle.arraylength
; The ORIGINAL allocation invoke (OrigAlloc %o) is RETAINED.
; CHECK: %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 12345 to ptr), i32 7, i32 44, i32 16, i32 1048576, i1 false, i1 false)
; No additional allocation invoke is emitted.
; CHECK-NOT: pea.mat = invoke
; Both normal paths replay the enter because both execute merge's real exit.
; The else replay is isolated on its incoming edge.
; CHECK: n:
; CHECK-NEXT: br i1 %c, label %then, label %else
; CHECK: then:
; CHECK-NEXT: call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(ptr addrspace(1) %o, ptr %lo)
; CHECK-NEXT: br label %merge
; CHECK: else:
; CHECK-NEXT: br label %[[EDGE:[-A-Za-z$._0-9]+]]
; CHECK: [[EDGE]]:
; CHECK-NEXT: call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(ptr addrspace(1) %o, ptr %lo)
; CHECK-NEXT: br label %merge
; CHECK: merge:
; CHECK-NEXT: %p = phi ptr addrspace(1) [ null, %then ], [ %o, %[[EDGE]] ]
; CHECK-NEXT: call void @sink(ptr addrspace(1) %p)
; CHECK-NEXT: call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(ptr addrspace(1) %o, ptr %lo)
; CHECK-NEXT: ret void
; Allocation unwind occurs before the virtual enter, so it contains no monitor
; operation. The folded arraylength unwind also disappeared with the invoke.
; CHECK: u:
; CHECK-NOT: @jeandle.monitor
; CHECK-NOT: poison
; CHECK: }
