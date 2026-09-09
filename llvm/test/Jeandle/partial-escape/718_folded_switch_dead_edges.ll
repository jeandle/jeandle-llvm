; RUN: opt -S -verify-each \
; RUN:   -passes="require<partial-escape-analysis>,partial-escape-transform" \
; RUN:   %s | FileCheck %s

; The switch condition is a PEA-folded arraylength. Case 1 and case 2 share a
; destination, and case 2 is feasible, so the (dispatch, shared) contribution
; is Live even though the first structural edge to that destination is dead.
; The default arm is impossible and must not materialize %o.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32)
declare hotspotcc i32 @jeandle.arraylength(ptr addrspace(1) readonly)
declare void @escape(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define i32 @folded_switch_duplicate_destination()
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 71801 to ptr), i32 24, i1 false)
      to label %array.alloc unwind label %alloc.unwind

array.alloc:
  %array = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
      ptr inttoptr (i64 71802 to ptr), i32 2, i32 4, i32 16, i32 1048576)
      to label %dispatch unwind label %alloc.unwind

dispatch:
  %len = call hotspotcc i32 @jeandle.arraylength(
      ptr addrspace(1) %array)
  switch i32 %len, label %dead.default [
    i32 1, label %shared
    i32 2, label %shared
  ]

dead.default:
  call void @escape(ptr addrspace(1) %o)
  br label %merge

shared:
  %field = getelementptr inbounds i8, ptr addrspace(1) %o, i64 16
  store atomic i32 52, ptr addrspace(1) %field unordered, align 4
  br label %merge

merge:
  %reload = getelementptr inbounds i8, ptr addrspace(1) %o, i64 16
  %value = load atomic i32, ptr addrspace(1) %reload unordered, align 4
  ret i32 %value

alloc.unwind:
  %ex = landingpad i64 cleanup
  resume i64 %ex
}

; CHECK-LABEL: define i32 @folded_switch_duplicate_destination()
; CHECK-NOT: @jeandle.new_instance
; CHECK-NOT: @jeandle.new_array
; CHECK-NOT: @jeandle.arraylength
; CHECK-NOT: @escape
; CHECK-NOT: dead.default:
; CHECK-NOT: alloc.unwind:
; CHECK-NOT: load atomic
; CHECK-NOT: store atomic
; CHECK-NOT: poison
; CHECK: ret i32 52

!java-method-compilation = !{}
