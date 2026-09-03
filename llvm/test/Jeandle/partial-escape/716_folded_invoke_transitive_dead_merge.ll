; RUN: opt -S -verify-each \
; RUN:   -passes="require<partial-escape-analysis>,partial-escape-transform" \
; RUN:   %s | FileCheck %s

; Folding %len removes folded.invoke's unwind edge.  Its dead-only landingpad
; flows into %handler, which is also reached through a real unwind.  The dead
; contribution must stay dead transitively: %handler inherits only
; live.lpad's state, so the nested outer -> inner virtual-object chain remains
; available for load folding and deopt description.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1) nounwind
declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32) nounwind
declare hotspotcc i32 @jeandle.arraylength(ptr addrspace(1) readonly)
declare void @may_throw()
declare void @safepoint()
declare i32 @__gxx_personality_v0(...)

define i32 @folded_invoke_transitive_dead_merge()
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %inner = call hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 71602 to ptr), i32 24, i1 false)
      [ "deopt"(i32 716021) ]
  %inner.field = getelementptr inbounds i8, ptr addrspace(1) %inner, i64 16
  store atomic i32 73, ptr addrspace(1) %inner.field unordered, align 4

  %outer = call hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 71601 to ptr), i32 24, i1 false)
      [ "deopt"(i32 716011) ]
  %outer.field = getelementptr inbounds i8, ptr addrspace(1) %outer, i64 16
  store atomic ptr addrspace(1) %inner, ptr addrspace(1) %outer.field unordered, align 8

  %array = call hotspotcc ptr addrspace(1) @jeandle.new_array(
      ptr inttoptr (i64 71603 to ptr), i32 7, i32 4, i32 16, i32 1048576)
      [ "deopt"(i32 716031) ]
  %len = invoke hotspotcc i32 @jeandle.arraylength(
      ptr addrspace(1) %array)
      to label %live.invoke unwind label %dead.lpad

dead.lpad:
  %dead.ex = landingpad i64 cleanup
  br label %handler

live.invoke:
  invoke void @may_throw()
      to label %normal unwind label %live.lpad

normal:
  ret i32 %len

live.lpad:
  %live.ex = landingpad i64 cleanup
  br label %handler

handler:
  %outer.field.reload =
      getelementptr inbounds i8, ptr addrspace(1) %outer, i64 16
  %inner.reload = load atomic ptr addrspace(1),
      ptr addrspace(1) %outer.field.reload unordered, align 8
  %inner.field.reload =
      getelementptr inbounds i8, ptr addrspace(1) %inner.reload, i64 16
  %value = load atomic i32, ptr addrspace(1) %inner.field.reload unordered, align 4
  call void @safepoint()
      [ "deopt"(i32 71, i32 71, i64 12, ptr addrspace(1) %outer) ]
  ret i32 %value
}

; CHECK-LABEL: define i32 @folded_invoke_transitive_dead_merge()
; CHECK-NOT: @jeandle.new_instance
; CHECK-NOT: @jeandle.new_array
; CHECK-NOT: @jeandle.arraylength
; CHECK-NOT: dead.lpad:
; CHECK: live.invoke:
; CHECK-NEXT: invoke void @may_throw()
; CHECK: live.lpad:
; CHECK: handler:
; CHECK-NOT: poison
; Root-first dense numbering emits outer at wire id 0, with one offset-16
; VORef field to the transitively discovered inner at wire id 1. The inner
; descriptor has one offset-16 integer field with value 73. The original outer
; local becomes a VORef to wire id 0.
; CHECK-NEXT: call void @safepoint() [ "deopt"(i32 71, i32 71, i64 262156, i64 71601, i32 1, i64 68720001036, i32 1, i64 4295229452, i64 71602, i32 1, i64 68719476746, i32 73, i64 524300, i32 0) ]{{$}}
; CHECK-NOT: poison
; CHECK-NEXT: ret i32 73
; CHECK-NOT: load atomic
; CHECK-NOT: store atomic
; CHECK-NOT: poison

!java-method-compilation = !{}
