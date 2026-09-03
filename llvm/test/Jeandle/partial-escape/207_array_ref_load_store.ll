; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" -jeandle-vm-callback-log=%S/Inputs/207_array_ref_load_store.cblog %s | FileCheck %s

; Object[] virtual — typed-element GEPs at constant indices, storing /
; reloading a wide reference. The fixture deliberately uses an 8-byte
; element scale so the VM layout matches the addrspace(1) pointer stride.

@arrayOopDesc.element_size.object = private constant i32 8

declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32)

declare i32 @__gxx_personality_v0(...)

define ptr addrspace(1) @test_obj_array(ptr addrspace(1) %v) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %arr = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
            ptr inttoptr (i64 22222 to ptr), i32 4, i32 48, i32 16, i32 1048576)
         to label %n unwind label %u
n:
  %base = getelementptr inbounds i8, ptr addrspace(1) %arr, i32 16
  %p2 = getelementptr inbounds ptr addrspace(1), ptr addrspace(1) %base, i64 2
  store atomic ptr addrspace(1) %v, ptr addrspace(1) %p2 unordered, align 8
  %r = load atomic ptr addrspace(1), ptr addrspace(1) %p2 unordered, align 8
  ret ptr addrspace(1) %r
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define ptr addrspace(1) @test_obj_array
; CHECK-NOT: jeandle.new_array
; CHECK-NOT: store
; CHECK-NOT: load
; CHECK: ret ptr addrspace(1) %v

!java-method-compilation = !{}
