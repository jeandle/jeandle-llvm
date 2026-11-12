; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" -jeandle-vm-callback-log=%S/Inputs/408_array_header_offset_guard.cblog %s | FileCheck %s

; An array-header access (a raw GEP into the bytes below ArrayBaseOffset, here
; offset 4 with ArrayBaseOffset=16 — the mark/klass region) is VM metadata, not
; a Java field, and must not be virtualized into a field slot. resolveAccess
; guards both instance and array header offsets, so this access is rejected and
; the array stays real.

declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32, i1, i1)
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @test_array_header_offset_guard() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %arr = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
            ptr inttoptr (i64 9999 to ptr), i32 4, i32 32, i32 16, i32 1048576, i1 false, i1 false)
       to label %n unwind label %u
n:
  ; Raw i8 GEP into the array header (offset 4 < ArrayBaseOffset 16).
  %ph = getelementptr i8, ptr addrspace(1) %arr, i64 4
  store i32 111, ptr addrspace(1) %ph
  call void @sink(ptr addrspace(1) %arr)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; The header store cannot be virtualized -> the array stays real (orig alloc)
; and the store survives on the real header.
; CHECK-LABEL: define void @test_array_header_offset_guard
; CHECK: jeandle.new_array
; CHECK: store i32 111

!java-method-compilation = !{}
