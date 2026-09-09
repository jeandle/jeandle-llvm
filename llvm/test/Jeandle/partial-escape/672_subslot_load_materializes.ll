; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; processLoad sub-slot read: a written i64 field at offset 8 is read back as
; an i32 at offset 12 (WithinSlotByteOff != 0). The partial-field load
; cannot be folded, so the object materializes AT the load:
; the i64 store is replayed immediately before it and
; the load survives as a real sub-slot load. Regression guard: marking the
; object ineligible instead would leave the i64 store in place (no replay).

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare i32 @__gxx_personality_v0(...)

define i32 @test_subslot_load() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
           ptr inttoptr (i64 12345 to ptr), i32 32, i1 false)
       to label %n unwind label %u
n:
  %f = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  store atomic i64 123456789, ptr addrspace(1) %f unordered, align 8
  %sub = getelementptr inbounds i8, ptr addrspace(1) %o, i64 12
  %v = load atomic i32, ptr addrspace(1) %sub unordered, align 4
  ret i32 %v
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define i32 @test_subslot_load
; CHECK: invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; The i64 store is replayed immediately before the surviving sub-slot load.
; CHECK: %pea.matslot = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
; CHECK: store atomic i64 123456789, ptr addrspace(1) %pea.matslot unordered, align 8
; CHECK: %v = load atomic i32, ptr addrspace(1) %sub unordered, align 4
; CHECK: ret i32 %v

!java-method-compilation = !{}
