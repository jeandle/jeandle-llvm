; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" -jeandle-vm-callback-log=%S/Inputs/209_array_overwrite_null.cblog %s | FileCheck %s

; Object[] virtual — store a reference into element 0, then overwrite it with
; null, then reload. PEA must track the overwrite (the live element value is
; the SECOND store, null) and replace the reload with null, eliminating the
; array and both element stores. This is the scalar-replacement analog of
; `array[0]=v; array[0]=null; array[0]==null`; in the full pipeline GVN folds
; that final load before PEA sees it, so this fixture verifies PEA's own
; overwrite tracking and load replacement in isolation.

@arrayOopDesc.element_size.object = private constant i32 8

declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32, i1, i1)
declare i32 @__gxx_personality_v0(...)

define ptr addrspace(1) @test_obj_array_overwrite_null(ptr addrspace(1) %v) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %arr = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
            ptr inttoptr (i64 22222 to ptr), i32 1, i32 32, i32 16, i32 1048576, i1 false, i1 false)
         to label %n unwind label %u
n:
  %base = getelementptr inbounds i8, ptr addrspace(1) %arr, i32 16
  %e0 = getelementptr inbounds ptr addrspace(1), ptr addrspace(1) %base, i64 0
  store atomic ptr addrspace(1) %v, ptr addrspace(1) %e0 unordered, align 8
  store atomic ptr addrspace(1) null, ptr addrspace(1) %e0 unordered, align 8
  %r = load atomic ptr addrspace(1), ptr addrspace(1) %e0 unordered, align 8
  ret ptr addrspace(1) %r
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; The reload is replaced with the last-write-wins value (null), not the first
; store's %v; the array and both stores are gone.
; CHECK-LABEL: define ptr addrspace(1) @test_obj_array_overwrite_null
; CHECK-NOT: jeandle.new_array
; CHECK-NOT: store
; CHECK-NOT: load
; CHECK: ret ptr addrspace(1) null

!java-method-compilation = !{}
