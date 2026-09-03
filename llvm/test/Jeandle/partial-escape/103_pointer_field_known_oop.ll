; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Edge case: virtual with a pointer field that holds a non-virtual,
; externally-supplied oop (a function argument). The virtual escapes via
; return; materialization must replay the pointer store using the original
; argument value.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare i32 @__gxx_personality_v0(...)

define ptr addrspace(1) @test_pointer_field_known_oop(ptr addrspace(1) %arg) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %n unwind label %u
n:
  %s = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  store atomic ptr addrspace(1) %arg, ptr addrspace(1) %s unordered, align 8
  ret ptr addrspace(1) %o
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; Materialization replays the pointer store of %arg into offset 8.
; CHECK-LABEL: define ptr addrspace(1) @test_pointer_field_known_oop
; CHECK: %[[MAT:[A-Za-z0-9._]+]] = invoke hotspotcc{{.*}}ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
; CHECK: %[[SLOT:[A-Za-z0-9._]+]] = getelementptr inbounds i8, ptr addrspace(1) %[[MAT]], i64 8
; CHECK: store atomic ptr addrspace(1) %arg, ptr addrspace(1) %[[SLOT]] unordered
; CHECK: ret ptr addrspace(1) %[[MAT]]

!java-method-compilation = !{}
