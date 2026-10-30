; RUN: opt -S -passes=java-op-length-folding %s | FileCheck %s

; The length argument may be a non-constant SSA value: fold to the value.
; Also covers looking through freeze.

declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32, i1, i1)
declare hotspotcc i32 @jeandle.arraylength(ptr addrspace(1) readonly)

declare i32 @__gxx_personality_v0(...)

define i32 @test_ssa_length(i32 %n) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %arr = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
            ptr inttoptr (i64 12345 to ptr), i32 %n, i32 44, i32 16, i32 1048576, i1 false, i1 false)
         to label %ok unwind label %u
ok:
  %len = call hotspotcc i32 @jeandle.arraylength(ptr addrspace(1) %arr)
  ret i32 %len
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

define i32 @test_ssa_length_frozen(i32 %n) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %arr = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
            ptr inttoptr (i64 12345 to ptr), i32 %n, i32 44, i32 16, i32 1048576, i1 false, i1 false)
         to label %ok unwind label %u
ok:
  %fr = freeze ptr addrspace(1) %arr
  %len = call hotspotcc i32 @jeandle.arraylength(ptr addrspace(1) %fr)
  ret i32 %len
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define i32 @test_ssa_length
; CHECK-NOT: jeandle.arraylength
; CHECK: ret i32 %n

; CHECK-LABEL: define i32 @test_ssa_length_frozen
; CHECK-NOT: jeandle.arraylength
; CHECK: ret i32 %n

!java-method-compilation = !{}
