; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; PEA negative: the array escapes via an opaque sink call before
; jeandle.arraylength is invoked. The allocation and the array_length
; call must both survive (no folding).

declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32, i1, i1)
declare hotspotcc i32 @jeandle.arraylength(ptr addrspace(1) readonly)

declare i32 @__gxx_personality_v0(...)
declare void @sink(ptr addrspace(1))

define i32 @test_arraylength_escape() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %arr = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
            ptr inttoptr (i64 12345 to ptr), i32 5, i32 36, i32 16, i32 1048576, i1 false, i1 false)
         to label %n unwind label %u
n:
  call void @sink(ptr addrspace(1) %arr)
  %len = call hotspotcc i32 @jeandle.arraylength(ptr addrspace(1) %arr)
  ret i32 %len
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define i32 @test_arraylength_escape
; CHECK: jeandle.new_array
; CHECK: jeandle.arraylength

!java-method-compilation = !{}
