; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" -jeandle-vm-callback-log=%S/Inputs/201_array_i8_gep_with_calculation.cblog %s | FileCheck %s

; int[] virtual where store and reload use a single i8 GEP whose
; byte offset is structurally `add ArrayBaseOffset, (shl idx, log2(scale))`
; with the same symbolic %idx for both accesses. matchArrayElementGEP
; sees a non-constant index and (per the "index constant only" policy)
; forces the array to materialize so that
; both accesses execute against a real array pointer.

declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32, i1, i1)
declare void @sink(i32)

declare i32 @__gxx_personality_v0(...)

define void @test_i8_calc_symbolic(i64 %idx) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %arr = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
            ptr inttoptr (i64 12345 to ptr), i32 4, i32 32, i32 16, i32 1048576, i1 false, i1 false)
         to label %n unwind label %u
n:
  %scaled = shl i64 %idx, 2
  %byteoff = add i64 16, %scaled
  %elem = getelementptr inbounds i8, ptr addrspace(1) %arr, i64 %byteoff
  store atomic i32 77, ptr addrspace(1) %elem unordered, align 4
  %v = load atomic i32, ptr addrspace(1) %elem unordered, align 4
  call void @sink(i32 %v)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; The matcher saw the array-element shape with a symbolic index and bailed,
; so the alloc, the store, and the load all survive.
; CHECK-LABEL: define void @test_i8_calc_symbolic
; CHECK: jeandle.new_array
; CHECK: store atomic i32 77
; CHECK: load atomic i32

!java-method-compilation = !{}
