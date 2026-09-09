; RUN: opt -disable-output -passes="require<partial-escape-analysis>" \
; RUN:   -jeandle-trace-pea %s 2>&1 | FileCheck %s --check-prefix=TRACE \
; RUN:   --implicit-check-not='PEA: Materialize function=@invoke_materialized_child_unwind_snapshot [VO=1] block=%handler'
; RUN: opt -S -verify-each \
; RUN:   -passes="require<partial-escape-analysis>,partial-escape-transform" \
; RUN:   %s | FileCheck %s

; Materializing %child immediately before the invoke also materializes it on
; the unwind edge.  The unwind snapshot must update %outer.child from a
; VirtualRef(%child) to a MaterializedRef(%child), just like the normal state.
; Otherwise the final normal/exception merge sees an inconsistent nested
; graph and emits a redundant third replay in %handler.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define i32 @invoke_materialized_child_unwind_snapshot(i1 %take.call)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %outer = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 11111 to ptr), i32 24, i1 false)
      to label %alloc.child unwind label %alloc.unwind

alloc.child:
  %child = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 22222 to ptr), i32 24, i1 false)
      to label %body unwind label %alloc.unwind

body:
  %outer.child = getelementptr inbounds i8, ptr addrspace(1) %outer, i64 8
  store atomic ptr addrspace(1) %child,
      ptr addrspace(1) %outer.child unordered, align 8
  %child.value = getelementptr inbounds i8, ptr addrspace(1) %child, i64 16
  store atomic i32 42, ptr addrspace(1) %child.value unordered, align 4
  br i1 %take.call, label %call, label %no.call

call:
  invoke void @sink(ptr addrspace(1) %child)
      to label %call.cont unwind label %handler

call.cont:
  br label %normal.merge

no.call:
  br label %normal.merge

normal.merge:
  %loaded.child = load atomic ptr addrspace(1),
      ptr addrspace(1) %outer.child unordered, align 8
  %loaded.value.addr =
      getelementptr inbounds i8, ptr addrspace(1) %loaded.child, i64 16
  %loaded.value =
      load atomic i32, ptr addrspace(1) %loaded.value.addr unordered, align 4
  br label %exit

handler:
  %exception = landingpad i64 cleanup
  br label %exit

exit:
  %result = phi i32 [ %loaded.value, %normal.merge ], [ 0, %handler ]
  ret i32 %result

alloc.unwind:
  %allocation.exception = landingpad i64 cleanup
  resume i64 %allocation.exception
}

; The child is replayed before @sink and on the no-call predecessor.  The
; invoke's unwind edge inherits the first replay and must not add a third.
; TRACE: PEA: Materialize function=@invoke_materialized_child_unwind_snapshot [VO=1] block=%call
; TRACE: PEA: Materialize function=@invoke_materialized_child_unwind_snapshot [VO=1] block=%no.call

; The outer allocation is eliminated; the partially escaping child allocation
; remains and its scalar field is replayed before the call.
; CHECK-LABEL: define i32 @invoke_materialized_child_unwind_snapshot(
; CHECK-NOT: @jeandle.new_instance(ptr inttoptr (i64 11111 to ptr)
; CHECK: %[[CHILD:[A-Za-z0-9._]+]] = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
; CHECK: call:
; CHECK: store atomic i32 42, ptr addrspace(1) %{{.*}} unordered, align 4
; CHECK: invoke void @sink(ptr addrspace(1) %[[CHILD]])
; CHECK: handler:
; CHECK-NOT: store atomic i32 42
; CHECK: br label %exit

!java-method-compilation = !{}
