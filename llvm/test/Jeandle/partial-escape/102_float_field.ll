; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Edge case: virtual with a float field at offset 8. The object
; escapes via return; materialization must replay the float store correctly
; (float is a primitive, not a reference, and uses 4-byte alignment).

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare i32 @__gxx_personality_v0(...)

define ptr addrspace(1) @test_float_field() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %n unwind label %u
n:
  %s = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  store atomic float 0x40091EB860000000, ptr addrspace(1) %s unordered, align 4
  ret ptr addrspace(1) %o
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; Retained OrigAlloc + replayed float store at offset 8.
; CHECK-LABEL: define ptr addrspace(1) @test_float_field
; CHECK: %[[ORIG:[A-Za-z0-9._]+]] = invoke hotspotcc{{.*}}ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
; CHECK-NOT: @jeandle.new_instance
; CHECK: %[[SLOT:[A-Za-z0-9._]+]] = getelementptr inbounds i8, ptr addrspace(1) %[[ORIG]], i64 8
; The replayed atomic store must carry natural 4-byte alignment for a float
; (a hardcoded align 1 would be an under-aligned atomic store — illegal).
; CHECK: store atomic float 0x40091EB860000000, ptr addrspace(1) %[[SLOT]] unordered, align 4
; CHECK: ret ptr addrspace(1) %[[ORIG]]

!java-method-compilation = !{}
