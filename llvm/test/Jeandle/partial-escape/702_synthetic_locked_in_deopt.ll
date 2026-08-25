; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s --check-prefix=IR

; A Case-C synthetic VO held in a balanced synchronized block (monitorenter/
; monitorexit on the merged %p, both folded by PEA) and referenced from a
; safepoint's deopt bundle both as a locals slot AND as a monitor owner. The
; synthetic is virtual at the safepoint, so it is DESCRIBED (descriptor +
; VORef local slot) and the monitor entry is rewritten to eliminated=true with
; a VORef owner (vo-id), so HotSpot relock_objects re-acquires the lock on the
; realloc'd synthetic at deopt. Mirrors 645 for an ordinary locked VO.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1) nounwind
declare hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1), ptr) nounwind
declare hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1), ptr) nounwind
declare void @safepoint()

define void @synthetic_locked_in_deopt(i1 %c) gc "hotspotgc" {
entry:
  %lock = alloca i64, align 8
  br i1 %c, label %left, label %right
left:
  %a = call hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 70201 to ptr), i32 24, i1 false) [ "deopt"(i32 702011) ]
  %af = getelementptr inbounds i8, ptr addrspace(1) %a, i64 8
  store atomic i32 41, ptr addrspace(1) %af unordered, align 4
  br label %merge
right:
  %b = call hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 70201 to ptr), i32 24, i1 false) [ "deopt"(i32 702012) ]
  %bf = getelementptr inbounds i8, ptr addrspace(1) %b, i64 8
  store atomic i32 42, ptr addrspace(1) %bf unordered, align 4
  br label %merge
merge:
  %p = phi ptr addrspace(1) [ %a, %left ], [ %b, %right ]
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %p, ptr %lock)
  call void @safepoint()
      [ "deopt"(i32 99, i32 99,
               i64 12, ptr addrspace(1) %p,
               i64 196620, ptr addrspace(1) %p, ptr %lock) ]
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %p, ptr %lock)
  ret void
}

; IR-LABEL: define void @synthetic_locked_in_deopt(
; Source allocations eliminated; the folded monitorenter/monitorexit deleted.
; IR-NOT: @jeandle.new_instance
; IR-NOT: jeandle.monitorenter
; IR-NOT: jeandle.monitorexit
; IR-NOT: store atomic
; IR: %[[F:pea.casec.field.phi]] = phi i32 [ 41, %left ], [ 42, %right ]
; IR: call void @safepoint() [ "deopt"(
; IR-SAME: i32 99, i32 99,
; The root synthetic is assigned dense wire id 0: klass 70201, field_count 1,
; field offset 8 = merged PHI.
; IR-SAME: i64 262156, i64 70201, i32 1,
; IR-SAME: i64 34359738378, i32 %[[F]],
; %p locals slot -> VORef wire id 0.
; IR-SAME: i64 524300, i32 0,
; monitor entry rewritten to eliminated=true (index=1) with a VORef owner
; (wire id 0); the basic_lock %lock is preserved verbatim.
; IR-SAME: i64 4295163916, i32 0, ptr %lock) ]
; IR-NOT: addrspace(1) %p
; IR-NOT: poison

!java-method-compilation = !{}
