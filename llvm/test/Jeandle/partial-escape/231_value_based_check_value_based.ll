; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" -jeandle-vm-callback-log=%S/Inputs/231_value_based_check_value_based.cblog %s | FileCheck %s

; Virtual receiver of jeandle.check_if_value_based whose exact klass
; (7777) IS a value-based class. foldCheckIfValueBased queries
; IsValueBased(7777) = true and forces materialization — Eligible[ID]=false
; discards every PEA effect for the virtual, so the original allocation and
; the runtime check call survive in IR (the check operates on a real oop,
; preserving HotSpot's DiagnoseSyncOnValueBasedClasses warning semantics).
; Note: the @sink prevents trivial DCE of the check result so the call
; itself remains visible to FileCheck after PEA.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare hotspotcc i1 @jeandle.check_if_value_based(ptr addrspace(1))
declare void @sink(i1)

declare i32 @__gxx_personality_v0(...)

define void @test_value_based_is_vb() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 7777 to ptr), i32 16, i1 false)
       to label %n unwind label %u
n:
  %r = call hotspotcc i1 @jeandle.check_if_value_based(ptr addrspace(1) %o)
  call void @sink(i1 %r)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; The virtual is force-materialized: both the alloc and the check survive,
; and the check operates on the materialized oop (not folded to a constant).
; CHECK-LABEL: define void @test_value_based_is_vb
; CHECK: %[[O:[A-Za-z0-9._]+]] = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 7777 to ptr), i32 16, i1 false)
; CHECK: %[[R:[A-Za-z0-9._]+]] = call hotspotcc i1 @jeandle.check_if_value_based(ptr addrspace(1) %[[O]])
; CHECK: call void @sink(i1 %[[R]])

!java-method-compilation = !{}
