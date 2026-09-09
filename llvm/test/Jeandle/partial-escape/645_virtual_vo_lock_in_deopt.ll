; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Lock reconstruction at deopt for virtual objects: a NEVER-escaping
; instance VO held in a synchronized block (balanced monitorenter/exit, both
; folded by PEA) is referenced from a safepoint's "deopt" bundle both as a
; locals slot AND as a monitor entry. The VO is still virtual at the safepoint
; (the monitorenter was ELIMINATED), so:
;   * the VO is described by a ScalarValueType descriptor (as in 640);
;   * the locals slot becomes a VORefLocalType reference (as in 640);
;   * the MONITOR entry is rewritten to eliminated=true with a VORef owner
;     (enc index=1, object = i32 vo-id), so HotSpot relock_objects re-acquires
;     the lock on the realloc'd owner at deopt. The basic_lock slot is kept.
;
; Mirrors the standard virtualizing-EA deopt encoding: an eliminated monitor
; entry carrying a virtual-object owner reference.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1), ptr) nounwind
declare hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1), ptr) nounwind
declare void @sink(i32, i32)
declare i32 @__gxx_personality_v0(...)

define void @virtual_vo_lock_in_deopt(i32 %a, i32 %b) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
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
  ; Folded monitorenter on the virtual receiver (lock elision).
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(
                  ptr addrspace(1) %o, ptr %lock)
  %v1 = load atomic i32, ptr addrspace(1) %s1 unordered, align 4
  %v2 = load atomic i32, ptr addrspace(1) %s2 unordered, align 4
  ; Safepoint INSIDE the synchronized region. The bundle carries the duplicated
  ; BCI marker, one locals entry (enc LocalType index=0 T_OBJECT = 12, %o), and
  ; one monitor entry (enc MonitorType index=0 T_OBJECT = 196620, object %o,
  ; basic_lock %lock). Only scalar field values reach @sink; %o lives solely in
  ; the deopt bundle.
  call void @sink(i32 %v1, i32 %v2)
       [ "deopt"(i32 99, i32 99,
                 i64 12, ptr addrspace(1) %o,
                 i64 196620, ptr addrspace(1) %o, ptr %lock) ]
  ; Matching folded monitorexit (balanced -> LockCounts==0 at commit -> NeverEscapes).
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(
                  ptr addrspace(1) %o, ptr %lock)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @virtual_vo_lock_in_deopt
; The OrigAlloc invoke is eliminated (NeverEscapes), and the folded
; monitorenter/monitorexit calls are deleted.
; CHECK-NOT: jeandle.new_instance
; CHECK-NOT: jeandle.monitorenter
; CHECK-NOT: jeandle.monitorexit
; The surviving sink call still carries a "deopt" bundle.
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
; the OrigAlloc locals slot is replaced by a VORefLocalType reference
; (vo_id=0): (0<<32)|(8<<16)|12 = 524300, then i32 0.
; CHECK-SAME: i64 524300, i32 0,
; the monitor entry is rewritten to eliminated=true (index=1) with a VORef
; owner: (1<<32)|(3<<16)|12 = 4295163916, then i32 vo-id 0; the basic_lock
; %lock is preserved verbatim.
; CHECK-SAME: i64 4295163916, i32 0, ptr %lock) ]
; The eliminated OrigAlloc must not appear in the bundle.
; CHECK-NOT: addrspace(1) %o

!java-method-compilation = !{}
