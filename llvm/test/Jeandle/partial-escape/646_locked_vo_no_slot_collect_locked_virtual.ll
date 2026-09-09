; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Locked-virtual collection: a NEVER-escaping VO that is
; HELD IN A LOCKED MONITOR at the safepoint but is NOT referenced from any
; locals/stack slot — its OrigAlloc appears ONLY as a monitor entry's owner.
; Deopt must still describe the VO (so its lock can be reconstructed on the
; realloc'd owner) even though no interpreter slot references it. The analyzer's
; root-set collection sees OrigAlloc in the monitor tuple, so the VO is planned
; and described; the transform rewrites the monitor to eliminated=true with a
; VORef owner and emits the descriptor (no local-slot rewrite happens — there is
; no local slot).
;
; A locked virtual object that does not appear in any slot is still added to
; the virtual mapping so deopt restores its lock stack.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1), ptr) nounwind
declare hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1), ptr) nounwind
declare void @sink(i32, i32)
declare i32 @__gxx_personality_v0(...)

define void @locked_vo_no_slot(i32 %a, i32 %b) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %lock = alloca i64, align 8
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 24, i1 false)
       to label %n unwind label %u
n:
  %s1 = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  %s2 = getelementptr inbounds i8, ptr addrspace(1) %o, i64 16
  store atomic i32 %a, ptr addrspace(1) %s1 unordered, align 4
  store atomic i32 %b, ptr addrspace(1) %s2 unordered, align 4
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(
                  ptr addrspace(1) %o, ptr %lock)
  %v1 = load atomic i32, ptr addrspace(1) %s1 unordered, align 4
  %v2 = load atomic i32, ptr addrspace(1) %s2 unordered, align 4
  ; Safepoint INSIDE the synchronized region. The bundle carries ONLY the
  ; duplicated-BCI marker and ONE monitor entry (enc MonitorType index=0
  ; T_OBJECT = 196620, object %o, basic_lock %lock) — NO locals entry for %o.
  ; %o is observable solely as the monitor owner.
  call void @sink(i32 %v1, i32 %v2)
       [ "deopt"(i32 99, i32 99,
                 i64 196620, ptr addrspace(1) %o, ptr %lock) ]
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(
                  ptr addrspace(1) %o, ptr %lock)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @locked_vo_no_slot
; The OrigAlloc invoke + folded monitorenter/monitorexit are eliminated.
; CHECK-NOT: jeandle.new_instance
; CHECK-NOT: jeandle.monitorenter
; CHECK-NOT: jeandle.monitorexit
; CHECK: call void @sink(i32 %a, i32 %b)
; CHECK-SAME: [ "deopt"(
; duplicated-BCI marker preserved.
; CHECK-SAME: i32 99, i32 99,
; ScalarValueType VO descriptor header (vo_id=0): (0<<32)|(4<<16)|12 = 262156
; CHECK-SAME: i64 262156, i64 12345, i32 2,
; field 0 (offset 8, LocalType/T_INT): (8<<32)|10 = 34359738378 -> value %a
; CHECK-SAME: i64 34359738378, i32 %a,
; field 1 (offset 16, LocalType/T_INT): (16<<32)|10 = 68719476746 -> value %b
; CHECK-SAME: i64 68719476746, i32 %b,
; the monitor entry is rewritten to eliminated=true (index=1) with a VORef
; owner: (1<<32)|(3<<16)|12 = 4295163916, then i32 vo-id 0; basic_lock kept.
; There is NO VORef locals slot (none existed).
; CHECK-SAME: i64 4295163916, i32 0, ptr %lock) ]
; The eliminated OrigAlloc must not appear in the bundle.
; CHECK-NOT: addrspace(1) %o

!java-method-compilation = !{}
