; RUN: opt -S -passes=java-op-length-folding %s | FileCheck %s

; No fold: arraylength applied to a derived pointer (non-zero offset GEP),
; a non-constant-offset GEP, or a plain argument. Only whole-object
; references to new_array may fold.

declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32, i1, i1)
declare hotspotcc i32 @jeandle.arraylength(ptr addrspace(1) readonly)

declare i32 @__gxx_personality_v0(...)

define i32 @test_offset_gep(i64 %idx) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %arr = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
            ptr inttoptr (i64 12345 to ptr), i32 7, i32 44, i32 16, i32 1048576, i1 false, i1 false)
         to label %n unwind label %u
n:
  %g1 = getelementptr i8, ptr addrspace(1) %arr, i32 16
  %len1 = call hotspotcc i32 @jeandle.arraylength(ptr addrspace(1) %g1)
  %g2 = getelementptr i8, ptr addrspace(1) %arr, i64 %idx
  %len2 = call hotspotcc i32 @jeandle.arraylength(ptr addrspace(1) %g2)
  %sum = add i32 %len1, %len2
  ret i32 %sum
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

define i32 @test_plain_argument(ptr addrspace(1) %arr) {
  %len = call hotspotcc i32 @jeandle.arraylength(ptr addrspace(1) %arr)
  ret i32 %len
}

; CHECK-LABEL: define i32 @test_offset_gep
; CHECK: %len1 = call hotspotcc i32 @jeandle.arraylength
; CHECK: %len2 = call hotspotcc i32 @jeandle.arraylength

; CHECK-LABEL: define i32 @test_plain_argument
; CHECK: %len = call hotspotcc i32 @jeandle.arraylength

!java-method-compilation = !{}
