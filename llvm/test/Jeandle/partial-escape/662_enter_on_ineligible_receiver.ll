; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s
; RUN: opt -disable-output -jeandle-trace-pea \
; RUN:   -passes="require<partial-escape-analysis>,partial-escape-transform" %s 2>&1 \
; RUN:   | FileCheck %s --check-prefix=TRACE

; A monitorenter whose receiver resolves to an ALREADY-INELIGIBLE virtual
; object cannot be elided — the fold would be revoked at commit anyway.
; The surviving REAL enter must fire the strict-lock-order cascade
; (materializeVirtualLocksBefore), like the cannot-virtualize-lock
; path: the still-virtual %obj holding a shallower elided lock must
; materialize BEFORE the real enter, so its re-emitted lock lands below
; %bad's on the runtime lock stack instead of after it (inverted nesting).

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare hotspotcc void @jeandle.monitorenter_with_lightweight_lock(ptr addrspace(1), ptr) nounwind
declare hotspotcc void @jeandle.monitorexit_with_lightweight_lock(ptr addrspace(1), ptr) nounwind
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @enter_on_ineligible_receiver() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %lo = alloca i64, align 8
  %lb = alloca i64, align 8
  %obj = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
             ptr inttoptr (i64 9101 to ptr), i32 16, i1 false)
         to label %n1 unwind label %u
n1:
  ; Elided virtual lock on %obj at depth 0.
  tail call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
                  ptr addrspace(1) %obj, ptr %lo)
  %bad = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
             ptr inttoptr (i64 9102 to ptr), i32 16, i1 false)
         to label %n2 unwind label %u.locked
n2:
  ; Derived-pointer escape: keeps %bad real (ineligible but still "virtual"
  ; in the analyzer state, so the enter still resolves to it).
  %derived = getelementptr inbounds i8, ptr addrspace(1) %bad, i64 8
  call void @sink(ptr addrspace(1) %derived)
  ; REAL enter on the ineligible receiver — the cascade must materialize
  ; %obj (re-emitting its enter) BEFORE this call.
  call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
                  ptr addrspace(1) %bad, ptr %lb)
  call void @sink(ptr addrspace(1) %obj)
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
                  ptr addrspace(1) %bad, ptr %lb)
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
                  ptr addrspace(1) %obj, ptr %lo)
  ret void
u.locked:
  %locked.lp = landingpad i64 cleanup
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
                  ptr addrspace(1) %obj, ptr %lo)
  resume i64 %locked.lp
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; %obj's re-emitted enter precedes the real enter on %bad; all four monitor
; calls survive in nesting order.
; CHECK-LABEL: define void @enter_on_ineligible_receiver
; CHECK: %obj = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK: %bad = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK-NOT: tail call hotspotcc void @jeandle.monitorenter_with_lightweight_lock
; CHECK: call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(ptr addrspace(1) %obj,
; CHECK-NEXT: call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(ptr addrspace(1) %bad,
; CHECK: call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(ptr addrspace(1) %bad,
; CHECK: call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(ptr addrspace(1) %obj,
; TRACE: PEA: LockReplay function=@enter_on_ineligible_receiver

!java-method-compilation = !{}
