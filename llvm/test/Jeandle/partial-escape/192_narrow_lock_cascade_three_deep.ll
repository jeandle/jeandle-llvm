; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Three nested locks. The MIDDLE virtual escapes. Under
; the narrow cascade rule
;   other.minLockDepth < this.maxLockDepth
; we get:
;   - A (outermost): A.min = 0 < B.max = 1 -> CASCADE.
;   - C (innermost): C.min = 2, NOT < B.max = 1 -> NO cascade.
; So A and B both materialize at the sink; C stays virtual and its
; monitorenter/exit pair folds away. (A broader cascade rule would
; materialize C too — over-conservative.)

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare hotspotcc void @jeandle.monitorenter_with_lightweight_lock(ptr addrspace(1), ptr) nounwind
declare hotspotcc void @jeandle.monitorexit_with_lightweight_lock(ptr addrspace(1), ptr) nounwind
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @test_narrow_cascade_three_deep() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %lock_a = alloca i64, align 8
  %lock_b = alloca i64, align 8
  %lock_c = alloca i64, align 8
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 55555 to ptr), i32 16, i1 false)
       to label %na unwind label %u
na:
  %b = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 66666 to ptr), i32 16, i1 false)
       to label %nb unwind label %u
nb:
  %c = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 77777 to ptr), i32 16, i1 false)
       to label %nc unwind label %u
nc:
  call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
                  ptr addrspace(1) %a, ptr %lock_a)
  call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
                  ptr addrspace(1) %b, ptr %lock_b)
  call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
                  ptr addrspace(1) %c, ptr %lock_c)
  ; The middle one escapes.
  call void @sink(ptr addrspace(1) %b)
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
                  ptr addrspace(1) %c, ptr %lock_c)
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
                  ptr addrspace(1) %b, ptr %lock_b)
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
                  ptr addrspace(1) %a, ptr %lock_a)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; A and B materialize; C must NOT. Each materialize re-emits its monitorenter
; (outer A before inner B); the exits survive at source.
; CHECK-LABEL: define void @test_narrow_cascade_three_deep
; CHECK: %[[MATA:[A-Za-z0-9._]+]] = invoke hotspotcc{{.*}}ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 55555 to ptr), i32 16, i1 false)
; CHECK: %[[MATB:[A-Za-z0-9._]+]] = invoke hotspotcc{{.*}}ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 66666 to ptr), i32 16, i1 false)
; CHECK: call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(ptr addrspace(1) %[[MATA]],
; CHECK: call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(ptr addrspace(1) %[[MATB]],
; CHECK: call void @sink(ptr addrspace(1) %[[MATB]])
; CHECK: call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(ptr addrspace(1) %[[MATB]],
; CHECK: call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(ptr addrspace(1) %[[MATA]],
; C must NOT be materialized; no monitor calls should reference lock_c.
; CHECK-NOT: jeandle.new_instance(ptr inttoptr (i64 77777 to ptr)
; CHECK-NOT: jeandle.monitorenter_with_lightweight_lock{{.*}}%lock_c
; CHECK-NOT: jeandle.monitorexit_with_lightweight_lock{{.*}}%lock_c

!java-method-compilation = !{}
