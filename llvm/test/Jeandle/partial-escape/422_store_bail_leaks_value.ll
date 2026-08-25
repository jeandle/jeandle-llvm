; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; processStore value-side leak. A virtual Object[]
; %arr is stored into at a SYMBOLIC index. resolveVirtualRef(%elem) chases the
; GEP base to %arr's ObjectID, but resolveAccess(%elem) returns nullopt (the
; index is a non-constant SSA value, so matchArrayElementGEP / resolveFieldOffset
; cannot pin a byte offset). The stored value %v is itself a fresh virtual
; instance.
;
; The unvirtualizable store materializes BOTH %arr and %v AT the store
; (materializeOperandsAtStore), so the surviving store keeps the live %v
; pointer. Regression guard: a bail that only marks %arr ineligible would
; classify %v NeverEscapes and RAUW it to poison while the store survives,
; writing `store ptr poison` into the materialized array.

declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32)
declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare i32 @__gxx_personality_v0(...)

define void @test_store_bail_leaks_value(i64 %idx) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %arr = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
  ptr inttoptr (i64 22222 to ptr), i32 4, i32 32, i32 16, i32 1048576)
  to label %n unwind label %u
n:
  %v = call hotspotcc ptr addrspace(1) @jeandle.new_instance(
  ptr inttoptr (i64 99999 to ptr), i32 24, i1 false)
  %base = getelementptr inbounds i8, ptr addrspace(1) %arr, i32 16
  %elem = getelementptr inbounds ptr addrspace(1), ptr addrspace(1) %base, i64 %idx
  store atomic ptr addrspace(1) %v, ptr addrspace(1) %elem unordered, align 4
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @test_store_bail_leaks_value
; Both allocations survive (the gate materializes arr and value).
; CHECK: invoke{{.*}}@jeandle.new_array
; CHECK: call{{.*}}@jeandle.new_instance
; The value operand must NOT be replaced by poison.
; CHECK-NOT: store ptr addrspace(1) poison

!java-method-compilation = !{}
