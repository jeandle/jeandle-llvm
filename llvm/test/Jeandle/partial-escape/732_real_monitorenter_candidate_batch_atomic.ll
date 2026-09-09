; REQUIRES: asserts
; RUN: opt -S -verify-each \
; RUN:   -passes="require<partial-escape-analysis>,partial-escape-transform" \
; RUN:   -jeandle-vm-callback-log=%S/Inputs/730_late_ineligible_lock_cascade_atomic.cblog \
; RUN:   %s | FileCheck %s
; RUN: opt -disable-output -jeandle-trace-pea \
; RUN:   -passes="require<partial-escape-analysis>,partial-escape-transform" \
; RUN:   -jeandle-vm-callback-log=%S/Inputs/730_late_ineligible_lock_cascade_atomic.cblog \
; RUN:   %s 2>&1 | FileCheck %s --allow-empty --check-prefix=TRACE \
; RUN:     --implicit-check-not='PEA: LockReplay function=@real_enter_candidate_batch'

; A and B both hold elided virtual locks when the real C monitorenter is
; processed. materializeVirtualLocksBefore selects the two candidates in
; ObjectID order, A then B. They are one physical strict-order batch and must
; share one final-commit plan. The later RPO path makes only B ineligible; the
; complete A+B batch must roll back before transform application. Otherwise
; B's original depth-1 enter revives while A's depth-0 replay survives just
; before C, producing the illegal order B@1, A@0, C@2.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
    ptr addrspace(1), ptr) nounwind
declare hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
    ptr addrspace(1), ptr) nounwind
declare hotspotcc i1 @jeandle.check_if_value_based(ptr addrspace(1))
declare void @sink_i1(i1)
declare i32 @__gxx_personality_v0(...)

define void @real_enter_candidate_batch(ptr addrspace(1) %c, i1 %late)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %la = alloca i64, align 8
  %lb = alloca i64, align 8
  %lc = alloca i64, align 8
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
           ptr inttoptr (i64 73001 to ptr), i32 16, i1 false)
       to label %new.b unwind label %unwind
new.b:
  %b = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
           ptr inttoptr (i64 7777 to ptr), i32 16, i1 false)
       to label %dispatch unwind label %unwind
dispatch:
  ; Reverse postorder visits the second successor (%batch) first.
  br i1 %late, label %late.exit, label %batch
batch:
  tail call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
      ptr addrspace(1) %a, ptr %la)
  tail call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
      ptr addrspace(1) %b, ptr %lb)
  call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
      ptr addrspace(1) %c, ptr %lc)
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
      ptr addrspace(1) %c, ptr %lc)
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
      ptr addrspace(1) %b, ptr %lb)
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
      ptr addrspace(1) %a, ptr %la)
  ret void
late.exit:
  %is.vb = call hotspotcc i1 @jeandle.check_if_value_based(
      ptr addrspace(1) %b)
  call void @sink_i1(i1 %is.vb)
  ret void
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @real_enter_candidate_batch(
; Both allocation sites and the complete original A@0, B@1, C@2 enter order
; survive. No A replay may appear between B and C.
; CHECK: %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK: %b = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK: batch:
; CHECK-NEXT: tail call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(ptr addrspace(1) %a, ptr %la)
; CHECK-NEXT: tail call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(ptr addrspace(1) %b, ptr %lb)
; CHECK-NEXT: call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(ptr addrspace(1) %c, ptr %lc)
; CHECK-NEXT: call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(ptr addrspace(1) %c, ptr %lc)
; CHECK-NEXT: call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(ptr addrspace(1) %b, ptr %lb)
; CHECK-NEXT: call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(ptr addrspace(1) %a, ptr %la)
; CHECK-NEXT: ret void
; CHECK: late.exit:
; CHECK-NEXT: %is.vb = call hotspotcc i1 @jeandle.check_if_value_based(ptr addrspace(1) %b)
; CHECK-NEXT: call void @sink_i1(i1 %is.vb)
; CHECK-NEXT: ret void
; CHECK-NOT: pea.matslot
; TRACE-NOT: PEA: LockReplay function=@real_enter_candidate_batch

!java-method-compilation = !{}
