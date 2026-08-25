; REQUIRES: asserts
; RUN: opt -S -verify-each \
; RUN:   -passes="require<partial-escape-analysis>,partial-escape-transform" \
; RUN:   -jeandle-vm-callback-log=%S/Inputs/730_late_ineligible_lock_cascade_atomic.cblog \
; RUN:   %s | FileCheck %s
; RUN: opt -disable-output -jeandle-trace-pea \
; RUN:   -passes="require<partial-escape-analysis>,partial-escape-transform" \
; RUN:   -jeandle-vm-callback-log=%S/Inputs/730_late_ineligible_lock_cascade_atomic.cblog \
; RUN:   %s 2>&1 | FileCheck %s --allow-empty --check-prefix=TRACE \
; RUN:     --implicit-check-not='PEA: LockReplay function=@late_ineligible_lock_cascade'

; The escape arm is earlier in RPO.  Escaping the depth-1 locked %b first
; builds one strict-lock materialization plan containing %a@0 and %b@1.  The
; other arm then leaves only %b locked at a real function exit, making %b
; ineligible during final eligibility.  The complete co-materialization plan
; must roll back: keeping %a's replay after %b's original enter revives would
; invert the runtime lock stack.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
    ptr addrspace(1), ptr) nounwind
declare hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
    ptr addrspace(1), ptr) nounwind
declare hotspotcc i1 @jeandle.check_if_value_based(ptr addrspace(1))
declare void @sink(ptr addrspace(1))
declare void @sink_i1(i1)
declare i32 @__gxx_personality_v0(...)

define void @late_ineligible_lock_cascade(i1 %late)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %la = alloca i64, align 8
  %lb.escape = alloca i64, align 8
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
           ptr inttoptr (i64 73001 to ptr), i32 16, i1 false)
       to label %new.b unwind label %unwind
new.b:
  %b = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
           ptr inttoptr (i64 7777 to ptr), i32 16, i1 false)
       to label %dispatch unwind label %unwind
dispatch:
  ; Reverse postorder visits the second successor (%escape) first.
  br i1 %late, label %late.exit, label %escape
escape:
  tail call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
      ptr addrspace(1) %a, ptr %la)
  tail call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
      ptr addrspace(1) %b, ptr %lb.escape)
  call void @sink(ptr addrspace(1) %b)
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
      ptr addrspace(1) %b, ptr %lb.escape)
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
      ptr addrspace(1) %a, ptr %la)
  ret void
late.exit:
  ; This value-based-class check marks only %b ineligible after the escape arm
  ; already built the two-object replay plan.
  %is.vb = call hotspotcc i1 @jeandle.check_if_value_based(
      ptr addrspace(1) %b)
  call void @sink_i1(i1 %is.vb)
  ret void
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @late_ineligible_lock_cascade(
; Both allocation sites and every original enter survive.  In particular,
; there is no canonical replay of %a after either original %b enter.
; CHECK: %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK: %b = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK: escape:
; CHECK-NEXT: tail call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(ptr addrspace(1) %a, ptr %la)
; CHECK-NEXT: tail call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(ptr addrspace(1) %b, ptr %lb.escape)
; CHECK-NEXT: call void @sink(ptr addrspace(1) %b)
; CHECK-NEXT: call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(ptr addrspace(1) %b, ptr %lb.escape)
; CHECK-NEXT: call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(ptr addrspace(1) %a, ptr %la)
; CHECK: late.exit:
; CHECK-NEXT: %is.vb = call hotspotcc i1 @jeandle.check_if_value_based(ptr addrspace(1) %b)
; CHECK-NEXT: call void @sink_i1(i1 %is.vb)
; CHECK-NEXT: ret void
; CHECK-NOT: pea.matslot
; TRACE-NOT: PEA: LockReplay function=@late_ineligible_lock_cascade

!java-method-compilation = !{}
