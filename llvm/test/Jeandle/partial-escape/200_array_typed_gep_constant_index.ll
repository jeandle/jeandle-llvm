; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" -jeandle-vm-callback-log=%S/Inputs/200_array_typed_gep_constant_index.cblog %s | FileCheck %s

; int[] virtual array with typed-element GEP at constant indices 0/1/2.
; The abstract interpreter emits one i8 GEP for ArrayBaseOffset (=16) and a
; chained typed GEP per index, which matchArrayElementGEP must recognise.
; Stores then loads return the stored constants — the alloc, stores and
; loads are all eliminated, leaving only the sum constant 60.

declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32, i1, i1)

declare i32 @__gxx_personality_v0(...)

define i32 @test_typed_gep_const_idx() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %arr = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
            ptr inttoptr (i64 12345 to ptr), i32 4, i32 32, i32 16, i32 1048576, i1 false, i1 false)
         to label %n unwind label %u
n:
  %base = getelementptr inbounds i8, ptr addrspace(1) %arr, i32 16
  %p0 = getelementptr inbounds i32, ptr addrspace(1) %base, i64 0
  %p1 = getelementptr inbounds i32, ptr addrspace(1) %base, i64 1
  %p2 = getelementptr inbounds i32, ptr addrspace(1) %base, i64 2
  store atomic i32 10, ptr addrspace(1) %p0 unordered, align 4
  store atomic i32 20, ptr addrspace(1) %p1 unordered, align 4
  store atomic i32 30, ptr addrspace(1) %p2 unordered, align 4
  %v0 = load atomic i32, ptr addrspace(1) %p0 unordered, align 4
  %v1 = load atomic i32, ptr addrspace(1) %p1 unordered, align 4
  %v2 = load atomic i32, ptr addrspace(1) %p2 unordered, align 4
  %s = add i32 %v0, %v1
  %r = add i32 %s, %v2
  ret i32 %r
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define i32 @test_typed_gep_const_idx
; CHECK-NOT: jeandle.new_array
; CHECK-NOT: store
; CHECK-NOT: load
; CHECK: %s = add i32 10, 20
; CHECK: %r = add i32 %s, 30
; CHECK: ret i32 %r

!java-method-compilation = !{}
