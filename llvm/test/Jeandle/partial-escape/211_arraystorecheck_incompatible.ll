; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" -jeandle-vm-callback-log=%S/Inputs/211_arraystorecheck_incompatible.cblog %s | FileCheck %s

; Virtual Object[] (array klass 8888, element klass 4444) plus a
; virtual instance value whose exact klass (7777) is provably incompatible
; with the array's element klass. evalSubtypeRelation returns false
; (IsSubtype false, areKlassesIncompatible true via Exact=true). The check
; SURVIVES in IR and — per the processJavaOp contract (a non-deleted
; node materializes its virtual operands) — BOTH the array and the virtual value operand
; materialize, so the surviving array_store_check observes real pointers.

declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32)
declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare hotspotcc i1 @jeandle.array_store_check(ptr addrspace(1), ptr addrspace(1))

declare i32 @__gxx_personality_v0(...)

define i1 @test_storecheck_incompat() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %arr = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
            ptr inttoptr (i64 8888 to ptr), i32 4, i32 32, i32 16, i32 1048576)
         to label %n1 unwind label %u
n1:
  %v = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 7777 to ptr), i32 16, i1 false)
       to label %n2 unwind label %u
n2:
  %r = call hotspotcc i1 @jeandle.array_store_check(ptr addrspace(1) %v,
                                                    ptr addrspace(1) %arr)
  ret i1 %r
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define i1 @test_storecheck_incompat
; The surviving array_store_check must observe REAL operands — both the
; array and the (virtual) value materialize, never poison.
; CHECK: jeandle.new_array
; CHECK: jeandle.new_instance
; CHECK: jeandle.array_store_check

!java-method-compilation = !{}
