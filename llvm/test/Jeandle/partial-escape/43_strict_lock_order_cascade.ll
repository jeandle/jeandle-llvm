; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; PEA: two synchronized regions on two different virtuals, properly
; nested (A is the OUTER lock, B is the INNER lock). The INNER virtual B
; escapes via a sink call while both locks are held. With strict-lock
; order assumed, the narrow cascade rule
; ("other.minLockDepth < this.maxLockDepth") FIRES for A because A's
; outermost lock was acquired BEFORE B's most-recent lock — i.e. A is
; on the LM_LIGHTWEIGHT lock stack below B. To preserve the monitor
; stack ordering when B materializes, A must also be materialized at
; the same point. Both objects' monitorenter and monitorexit calls
; are retained on their respective materialized pointers.
;
; (The mirror case — outer A escapes while inner B is still virtual —
;  is exercised by 193_narrow_lock_no_cascade_needed.ll, where the
;  narrow rule correctly does NOT cascade B.)

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare hotspotcc void @jeandle.monitorenter_with_lightweight_lock(ptr addrspace(1), ptr) nounwind
declare hotspotcc void @jeandle.monitorexit_with_lightweight_lock(ptr addrspace(1), ptr) nounwind
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @test_strict_lock_cascade() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %lock_a = alloca i64, align 8
  %lock_b = alloca i64, align 8
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %na unwind label %u
na:
  %b = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 67890 to ptr), i32 16, i1 false)
       to label %nb unwind label %u
nb:
  ; Acquire outer A.
  call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
                  ptr addrspace(1) %a, ptr %lock_a)
  ; Acquire inner B.
  call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
                  ptr addrspace(1) %b, ptr %lock_b)
  ; Escape: the INNER object B leaks through a sink while both locks held.
  call void @sink(ptr addrspace(1) %b)
  ; Release inner B.
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
                  ptr addrspace(1) %b, ptr %lock_b)
  ; Release outer A.
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
                  ptr addrspace(1) %a, ptr %lock_a)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; Both A and B must be materialized: B because it escaped; A because the
; narrow cascade rule cascades the OUTER (still-virtual) lock when the
; INNER object is materialized. The locks re-emitted at the escape point are
; globally depth-sorted (flattened into one materialize commit):
; outer A (lock_a, depth 0) before inner B (lock_b, depth 1). The original
; monitorexits survive at their source locations.
; CHECK-LABEL: define void @test_strict_lock_cascade
; CHECK: %[[MATA:[A-Za-z0-9._]+]] = invoke hotspotcc{{.*}}ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
; CHECK: %[[MATB:[A-Za-z0-9._]+]] = invoke hotspotcc{{.*}}ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 67890 to ptr), i32 16, i1 false)
; CHECK: call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(ptr addrspace(1) %[[MATA]], ptr %lock_a)
; CHECK: call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(ptr addrspace(1) %[[MATB]], ptr %lock_b)
; CHECK: call void @sink(ptr addrspace(1) %[[MATB]])
; CHECK: call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(ptr addrspace(1) %[[MATB]],
; CHECK: call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(ptr addrspace(1) %[[MATA]],

!java-method-compilation = !{}
