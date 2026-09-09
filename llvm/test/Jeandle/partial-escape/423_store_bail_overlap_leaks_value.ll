; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; processStore value-side leak. Two stores hit the
; SAME field offset with incompatible types: an i32 store creates a 4-byte
; field @8, then a reference (ptr) store at @8 makes getOrCreateFieldIndex
; return -1 (ByteSize/IsReference mismatch) -> bail path 2. The second store's
; value %v is a fresh virtual instance.
;
; The unvirtualizable store materializes BOTH %o and %v AT the store
; (materializeOperandsAtStore), so the surviving store keeps the live %v
; pointer. Regression guard: a bail that only marks %o ineligible would let
; %v leak (NeverEscapes -> poison) while the reference store survives as
; `store ptr poison`.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare i32 @__gxx_personality_v0(...)

define void @test_store_bail_overlap_leaks_value() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
  ptr inttoptr (i64 12345 to ptr), i32 32, i1 false)
  to label %n unwind label %u
n:
  %v = call hotspotcc ptr addrspace(1) @jeandle.new_instance(
  ptr inttoptr (i64 99999 to ptr), i32 24, i1 false)
  %slot = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  store atomic i32 5, ptr addrspace(1) %slot unordered, align 4
  store atomic ptr addrspace(1) %v, ptr addrspace(1) %slot unordered, align 4
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @test_store_bail_overlap_leaks_value
; Both allocations survive (the gate materializes o and value).
; CHECK: invoke{{.*}}@jeandle.new_instance
; CHECK: call{{.*}}@jeandle.new_instance
; The value operand must NOT be replaced by poison.
; CHECK-NOT: store ptr addrspace(1) poison

!java-method-compilation = !{}
