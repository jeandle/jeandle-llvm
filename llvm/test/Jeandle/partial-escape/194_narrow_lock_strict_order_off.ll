; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" -jeandle-assume-strict-lock-order=false %s | FileCheck %s

; Even when the narrow rule WOULD cascade (the inner B escapes
; while A is still virtually locked outside — cf. 190_narrow_lock_cascade_nested.ll),
; passing -jeandle-assume-strict-lock-order=false disables the entire
; cascade. Only B materializes; A stays virtual and its monitorenter /
; monitorexit fold away. Verifies that the narrow rule plumbing didn't
; accidentally bypass the StrictLockOrder gate.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare hotspotcc void @jeandle.monitorenter_with_lightweight_lock(ptr addrspace(1), ptr) nounwind
declare hotspotcc void @jeandle.monitorexit_with_lightweight_lock(ptr addrspace(1), ptr) nounwind
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @test_narrow_strict_order_off() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %lock_a = alloca i64, align 8
  %lock_b = alloca i64, align 8
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 10101 to ptr), i32 16, i1 false)
       to label %na unwind label %u
na:
  %b = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 20202 to ptr), i32 16, i1 false)
       to label %nb unwind label %u
nb:
  call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
                  ptr addrspace(1) %a, ptr %lock_a)
  call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
                  ptr addrspace(1) %b, ptr %lock_b)
  ; Inner B escapes; under narrow rule WITH strict-order this would
  ; cascade A — but strict-order is OFF here.
  call void @sink(ptr addrspace(1) %b)
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
                  ptr addrspace(1) %b, ptr %lock_b)
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
                  ptr addrspace(1) %a, ptr %lock_a)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; Only B materializes.
; CHECK-LABEL: define void @test_narrow_strict_order_off
; CHECK: %[[MATB:[A-Za-z0-9._]+]] = invoke hotspotcc{{.*}}ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 20202 to ptr), i32 16, i1 false)
; CHECK: call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(ptr addrspace(1) %[[MATB]],
; CHECK: call void @sink(ptr addrspace(1) %[[MATB]])
; CHECK: call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(ptr addrspace(1) %[[MATB]],
; A must NOT materialize (cascade disabled).
; CHECK-NOT: jeandle.new_instance(ptr inttoptr (i64 10101 to ptr)
; CHECK-NOT: jeandle.monitorenter_with_lightweight_lock{{.*}}%lock_a
; CHECK-NOT: jeandle.monitorexit_with_lightweight_lock{{.*}}%lock_a

!java-method-compilation = !{}
