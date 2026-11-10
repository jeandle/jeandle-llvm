; RUN: opt -S -passes=java-op-length-folding -verify-each %s | FileCheck %s

; Folding looks through bitcast, same-address-space addrspacecast, freeze,
; and zero-offset GEPs. Also: a length chain — new int[a.length] — folds
; both calls (the second fold's recorded length is the first call, which
; the first fold RAUWs to a constant).

declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32, i1, i1)
declare hotspotcc i32 @jeandle.arraylength(ptr addrspace(1) readonly)

declare i32 @__gxx_personality_v0(...)

define i32 @test_cast_chain(i32 %n) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %arr = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
            ptr inttoptr (i64 12345 to ptr), i32 %n, i32 44, i32 16, i32 1048576, i1 false, i1 false)
         to label %ok unwind label %u
ok:
  %g = getelementptr i8, ptr addrspace(1) %arr, i32 0
  %f = freeze ptr addrspace(1) %g
  %len = call hotspotcc i32 @jeandle.arraylength(ptr addrspace(1) %f)
  ret i32 %len
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

define i32 @test_length_chain() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a0 = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
           ptr inttoptr (i64 12345 to ptr), i32 7, i32 44, i32 16, i32 1048576, i1 false, i1 false)
        to label %n unwind label %u
n:
  %l1 = call hotspotcc i32 @jeandle.arraylength(ptr addrspace(1) %a0)
  %a1 = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
           ptr inttoptr (i64 12345 to ptr), i32 %l1, i32 44, i32 16, i32 1048576, i1 false, i1 false)
        to label %n2 unwind label %u
n2:
  %l2 = call hotspotcc i32 @jeandle.arraylength(ptr addrspace(1) %a1)
  ret i32 %l2
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define i32 @test_cast_chain
; CHECK-NOT: jeandle.arraylength
; CHECK: ret i32 %n

; CHECK-LABEL: define i32 @test_length_chain
; CHECK-NOT: jeandle.arraylength
; CHECK: ret i32 7

!java-method-compilation = !{}
