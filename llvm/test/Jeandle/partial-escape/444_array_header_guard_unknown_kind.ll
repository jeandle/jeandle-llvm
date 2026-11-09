; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Array header guard on an UNKNOWN element-kind array.
;
; When elementTypeForArrayKlass returns nullopt (klass not registered with a
; cblog), processAllocation sets ArrayBaseOffset to the VM's standard array
; base offset for an unknown kind (arrayBaseOffsetFor(JBasicType::Object) =
; 16, the uniform 16-byte default across all element kinds in VMConstants.h
; and HotSpot). Leaving it at the default 0 would degrade the resolveAccess
; header guard `*Offset < ArrayBaseOffset` to `*Offset < 0`, so a raw header
; GEP at offset 4 (the mark/klass region) would pass and be virtualized as
; Java field offset 0 — unsound (VM metadata corruption once the unsafe
; raw-header path opens). With the 16-byte default the guard `4 < 16` rejects
; the header store while element GEPs (offset >= 16, see test 397) still
; virtualize. The array stays real.

declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32, i1, i1)
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @test_array_header_guard_unknown_kind() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  ; Klass 7777 is NOT registered with any cblog -> element kind unknown ->
  ; ArrayBaseOffset defaults to 16 (not 0).
  %arr = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
            ptr inttoptr (i64 7777 to ptr), i32 4, i32 32, i32 16, i32 1048576, i1 false, i1 false)
         to label %n unwind label %u
n:
  ; Raw i8 GEP into the array header (offset 4 < 16).
  %ph = getelementptr i8, ptr addrspace(1) %arr, i64 4
  store i32 111, ptr addrspace(1) %ph
  call void @sink(ptr addrspace(1) %arr)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @test_array_header_guard_unknown_kind
; The header store cannot be virtualized (4 < 16 guard fires) -> the array
; stays real (orig alloc); no extra invoke and no replay slot is emitted.
; CHECK-NOT: pea.mat
; CHECK-NOT: pea.matslot
; The original array allocation and the original store survive.
; CHECK: jeandle.new_array
; CHECK: store i32 111
; CHECK: call void @sink

!java-method-compilation = !{}
