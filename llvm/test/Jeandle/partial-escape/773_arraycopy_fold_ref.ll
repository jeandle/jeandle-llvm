; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" -jeandle-vm-callback-log=%S/Inputs/773_arraycopy_fold_ref.cblog %s | FileCheck %s

; Object[] arraycopy fold with a VirtualRef element: the source holds a
; reference to a virtual object; the fold propagates the VirtualRef into the
; destination's field state. The source array never escapes (eliminated),
; while the destination escapes through @sink: it materializes at the sink
; with the copied element replayed, which recursively materializes the
; referenced object first. Element scale 8 / wide oop model.

@VMOptions.UseCompressedOops = private constant i1 false
@arrayOopDesc.element_size.object = private constant i32 8

declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32)
declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare hotspotcc void @jeandle.arraycopy(ptr addrspace(1), i64, ptr addrspace(1), i64, i64, ptr, ptr, i64, i64) #0

declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @test_arraycopy_fold_ref() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %inner = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 33333 to ptr), i32 16, i1 false)
         to label %n1 unwind label %u
n1:
  %src = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
            ptr inttoptr (i64 22222 to ptr), i32 4, i32 48, i32 16, i32 1048576)
         to label %n2 unwind label %u
n2:
  %dest = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
            ptr inttoptr (i64 22223 to ptr), i32 4, i32 48, i32 16, i32 1048576)
         to label %n3 unwind label %u
n3:
  %sbase = getelementptr inbounds i8, ptr addrspace(1) %src, i32 16
  %s0 = getelementptr inbounds ptr addrspace(1), ptr addrspace(1) %sbase, i64 0
  store atomic ptr addrspace(1) %inner, ptr addrspace(1) %s0 unordered, align 8
  invoke hotspotcc void @jeandle.arraycopy(
            ptr addrspace(1) %src, i64 0, ptr addrspace(1) %dest, i64 0, i64 1,
            ptr null, ptr null, i64 4, i64 4)
         to label %ac unwind label %u
ac:
  call void @sink(ptr addrspace(1) %dest)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

attributes #0 = { "jeandle.arraycopy.kind"="arraycopy" "jeandle.arraycopy.validated" }

; CHECK-LABEL: define void @test_arraycopy_fold_ref
; The pseudo call is folded away.
; CHECK-NOT: jeandle.arraycopy
; The referenced object materializes (kept real; it is the replay value).
; CHECK: jeandle.new_instance
; The source array is eliminated; only the destination array survives.
; CHECK-COUNT-1: invoke hotspotcc ptr addrspace(1) @jeandle.new_array
; The copied element is replayed as a real store of the referenced object
; into the materialized destination before the escape.
; CHECK: store atomic ptr addrspace(1) %inner
; CHECK: call void @sink

!java-method-compilation = !{}
