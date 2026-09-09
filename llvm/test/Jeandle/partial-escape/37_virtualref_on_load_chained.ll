; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Chained VirtualRef-on-load: a 3-deep chain.
;
; A.f(@8) = B, B.f(@8) = C; loading A.f yields B (still virtual via the
; alias install), loading that's f yields C (still virtual), and a
; jeandle.arraylength on the third-level load folds to C's compile-time
; length. Nothing escapes; all three allocations and both field stores
; disappear.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32)
declare hotspotcc i32 @jeandle.arraylength(ptr addrspace(1) readonly)
declare i32 @__gxx_personality_v0(...)

define i32 @test_virtualref_on_load_chained() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %c = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
            ptr inttoptr (i64 11111 to ptr), i32 9, i32 52, i32 16, i32 1048576)
       to label %nC unwind label %u1
nC:
  %b = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 22222 to ptr), i32 16, i1 false)
       to label %nB unwind label %u2
nB:
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 33333 to ptr), i32 16, i1 false)
       to label %nA unwind label %u3
nA:
  %slotB = getelementptr inbounds i8, ptr addrspace(1) %b, i64 8
  store atomic ptr addrspace(1) %c, ptr addrspace(1) %slotB unordered, align 8
  %slotA = getelementptr inbounds i8, ptr addrspace(1) %a, i64 8
  store atomic ptr addrspace(1) %b, ptr addrspace(1) %slotA unordered, align 8
  %loadedB = load atomic ptr addrspace(1), ptr addrspace(1) %slotA unordered, align 8
  %slotBfromA = getelementptr inbounds i8, ptr addrspace(1) %loadedB, i64 8
  %loadedC = load atomic ptr addrspace(1), ptr addrspace(1) %slotBfromA unordered, align 8
  %len = call hotspotcc i32 @jeandle.arraylength(ptr addrspace(1) %loadedC)
  ret i32 %len
u1:
  %lp1 = landingpad i64 cleanup
  resume i64 %lp1
u2:
  %lp2 = landingpad i64 cleanup
  resume i64 %lp2
u3:
  %lp3 = landingpad i64 cleanup
  resume i64 %lp3
}

; CHECK-LABEL: define i32 @test_virtualref_on_load_chained
; CHECK-NOT: jeandle.new_instance
; CHECK-NOT: jeandle.new_array
; CHECK-NOT: jeandle.arraylength
; CHECK-NOT: store atomic
; CHECK-NOT: load atomic
; CHECK: ret i32 9

!java-method-compilation = !{}
