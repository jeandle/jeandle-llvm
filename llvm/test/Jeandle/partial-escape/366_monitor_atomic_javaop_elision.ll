; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Regression for the "monitor op as a single complete JavaOp" refactor.
;
; Before the refactor, a monitorenter/monitorexit was emitted as a JavaOp
; (fast path) PLUS a separate SharedRuntime_complete_monitor_* slow-path call
; in user IR. PEA only recognised the fast-path call by name; the slow-path
; call fell through to materializeAllVirtualOperands and forced the receiver
; to materialise, defeating lock elision.
;
; Now the slow path lives INSIDE the JavaOp body, so PEA sees one opaque void
; call per monitor op and can elide the whole pair on a non-escaping receiver.
; This test pins that behaviour: both monitor calls (and the allocation) are
; gone, and no SharedRuntime_complete_monitor_* call leaks into the output
; (the slow path is only exposed later by JavaOperationLower, which this test
; does not run).

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare hotspotcc void @jeandle.monitorenter_with_lightweight_lock(ptr addrspace(1), ptr) nounwind
declare hotspotcc void @jeandle.monitorexit_with_lightweight_lock(ptr addrspace(1), ptr) nounwind

declare i32 @__gxx_personality_v0(...)

define void @atomic_monitor_pair() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %lock = alloca i64, align 8
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 777 to ptr), i32 16, i1 false)
       to label %locked unwind label %u
locked:
  call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
       ptr addrspace(1) %o, ptr %lock)
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
       ptr addrspace(1) %o, ptr %lock)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @atomic_monitor_pair
; CHECK-NOT: jeandle.new_instance
; CHECK-NOT: jeandle.monitorenter_with_lightweight_lock
; CHECK-NOT: jeandle.monitorexit_with_lightweight_lock
; CHECK-NOT: SharedRuntime_complete_monitor
; CHECK: ret void

!java-method-compilation = !{}
