; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s
;
; Regression test for array_length folding interacting with a later escape.
; The array_length call gets a ReplaceLoad effect (folds to constant 4); for
; the escape case a Materialize effect is also recorded at the @sink escape.
; Effects are applied in SeqNo order within a block, so the fold runs first.
;
; Edge case: a virtual array of length 4 has its array_length read before the
; array escapes. Two scenarios are exercised:
;
;   * test_length_then_eliminate: array_length is read, never escapes.
;     The length call folds to 4, and the alloc is eliminated entirely.
;
;   * test_length_then_escape: array_length is read first (folds to 4), THEN
;     the array escapes via @sink. The length call still folds; under the
;     reuse-OrigAlloc model the ORIGINAL new_array allocation is kept alive
;     and the sink consumes it directly.

declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32, i1, i1)
declare hotspotcc i32 @jeandle.arraylength(ptr addrspace(1) readonly)
declare void @use(i32)
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @test_length_then_eliminate() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %arr = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
            ptr inttoptr (i64 12345 to ptr), i32 4, i32 32, i32 16, i32 1048576, i1 false, i1 false)
         to label %n unwind label %u
n:
  %len = call hotspotcc i32 @jeandle.arraylength(ptr addrspace(1) %arr)
  call void @use(i32 %len)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @test_length_then_eliminate
; CHECK-NOT: jeandle.new_array
; CHECK-NOT: jeandle.arraylength
; CHECK: call void @use(i32 4)

define void @test_length_then_escape() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %arr = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
            ptr inttoptr (i64 12345 to ptr), i32 4, i32 32, i32 16, i32 1048576, i1 false, i1 false)
         to label %n unwind label %u
n:
  %len = call hotspotcc i32 @jeandle.arraylength(ptr addrspace(1) %arr)
  call void @use(i32 %len)
  call void @sink(ptr addrspace(1) %arr)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; The length call folds to 4 (independent of the later escape). Under
; reuse-OrigAlloc the ORIGINAL new_array invoke is retained (it precedes the
; length use, which precedes the sink); the sink consumes OrigAlloc directly.
; CHECK-LABEL: define void @test_length_then_escape
; CHECK: invoke hotspotcc{{.*}}ptr addrspace(1) @jeandle.new_array
; CHECK-NOT: invoke hotspotcc{{.*}}@jeandle.new_array
; CHECK-NOT: jeandle.arraylength
; CHECK: call void @use(i32 4)
; CHECK: call void @sink(ptr addrspace(1) %arr)

!java-method-compilation = !{}
