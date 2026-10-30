; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" -jeandle-vm-callback-log=%S/Inputs/80_oob_byte_gep_array_bails.cblog %s | FileCheck %s

; int[3] virtual array (ArrayBaseOffset=16, index scale 4). A byte-GEP at
; offset 28 = 16 + 3*4 is ONE PAST THE END (index 3, length 3) — out of
; bounds. matchArrayElementGEP (Pattern B) rejects it, and the upper-bound
; check (Offset >= ArrayBaseOffset + ArrayLength*scale) bails, so the array
; materializes at the offending store and the store survives.

declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32, i1, i1)

declare i32 @__gxx_personality_v0(...)

define void @test_oob_byte_gep_array_bails() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  ; length 3, ArrayBaseOffset 16, Int element (scale 4) via the cblog.
  %arr = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
            ptr inttoptr (i64 12345 to ptr), i32 3, i32 32, i32 16, i32 1048576, i1 false, i1 false)
       to label %n unwind label %u
n:
  ; In-bounds element 0 store, so the array is otherwise virtualizable.
  %base = getelementptr inbounds i8, ptr addrspace(1) %arr, i32 16
  %p0 = getelementptr inbounds i32, ptr addrspace(1) %base, i64 0
  store atomic i32 10, ptr addrspace(1) %p0 unordered, align 4
  ; OOB byte-GEP: offset 28 = 16 + 3*4 (index 3, one past the length-3 end).
  %bad = getelementptr inbounds i8, ptr addrspace(1) %arr, i64 28
  store atomic i32 99, ptr addrspace(1) %bad unordered, align 4
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; The OOB access cannot be virtualized, so the array materializes AT the OOB
; store: the alloc survives, the tracked in-bounds store is replayed onto
; OrigAlloc (pea.matslot) immediately before it, and the OOB store survives.
; CHECK-LABEL: define void @test_oob_byte_gep_array_bails
; CHECK: jeandle.new_array
; CHECK: store atomic i32 10
; CHECK: store atomic i32 99
; CHECK: ret void

!java-method-compilation = !{}
