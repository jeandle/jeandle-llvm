; RUN: opt -S -passes=java-op-length-folding %s | FileCheck %s

; Basic fold: arraylength(new_array(..., 7, ...)) folds to 7.
; The new_array itself stays (allocation elimination is PEA's job).

declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32, i1, i1)
declare hotspotcc i32 @jeandle.arraylength(ptr addrspace(1) readonly)

declare i32 @__gxx_personality_v0(...)

define i32 @test_constant_length() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %arr = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
            ptr inttoptr (i64 12345 to ptr), i32 7, i32 44, i32 16, i32 1048576, i1 false, i1 false)
         to label %n unwind label %u
n:
  %len = call hotspotcc i32 @jeandle.arraylength(ptr addrspace(1) %arr)
  ret i32 %len
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define i32 @test_constant_length
; CHECK: jeandle.new_array
; CHECK-NOT: jeandle.arraylength
; CHECK: ret i32 7

!java-method-compilation = !{}
