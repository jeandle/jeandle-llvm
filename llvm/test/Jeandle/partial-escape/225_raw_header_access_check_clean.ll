; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" -jeandle-pea-verify-header-access=fatal %s | FileCheck %s

; Fatal mode must not fire on the blessed shapes:
;   * jeandle.load_klass / jeandle.arraylength JavaOps fold by name;
;   * a field access at offset == instanceOopDesc.base_offset_in_bytes is a
;     legal instance field (the check is strictly-less-than);
;   * a raw i32 load exactly at arrayOopDesc.length_offset_in_bytes hits the
;     array-length safety-net fold (again offset == base, not below it).

@instanceOopDesc.base_offset_in_bytes = private constant i32 12
@arrayOopDesc.length_offset_in_bytes = private constant i32 12

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32)
declare hotspotcc ptr addrspace(0) @jeandle.load_klass(ptr addrspace(1))
declare hotspotcc i32 @jeandle.arraylength(ptr addrspace(1) readonly)

declare i32 @__gxx_personality_v0(...)

define ptr addrspace(0) @test_load_klass_clean() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %n unwind label %u
n:
  %k = call hotspotcc ptr addrspace(0) @jeandle.load_klass(ptr addrspace(1) %o)
  ret ptr addrspace(0) %k
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define ptr @test_load_klass_clean
; CHECK-NOT: jeandle.new_instance
; CHECK-NOT: jeandle.load_klass
; CHECK: ret ptr inttoptr (i64 12345 to ptr)

define i32 @test_field_at_base_offset() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %n unwind label %u
n:
  %f = getelementptr inbounds i8, ptr addrspace(1) %o, i64 12
  store atomic i32 42, ptr addrspace(1) %f unordered, align 4
  %v = load atomic i32, ptr addrspace(1) %f unordered, align 4
  ret i32 %v
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define i32 @test_field_at_base_offset
; CHECK-NOT: jeandle.new_instance
; CHECK: ret i32 42

define i32 @test_arraylength_clean() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %arr = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
            ptr inttoptr (i64 12345 to ptr), i32 7, i32 44, i32 16, i32 1048576)
         to label %n unwind label %u
n:
  %len = call hotspotcc i32 @jeandle.arraylength(ptr addrspace(1) %arr)
  ret i32 %len
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define i32 @test_arraylength_clean
; CHECK-NOT: jeandle.new_array
; CHECK: ret i32 7

define i32 @test_raw_array_length_load() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %arr = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
            ptr inttoptr (i64 12345 to ptr), i32 7, i32 44, i32 16, i32 1048576)
         to label %n unwind label %u
n:
  %len.addr = getelementptr inbounds i8, ptr addrspace(1) %arr, i64 12
  %len = load atomic i32, ptr addrspace(1) %len.addr unordered, align 4
  ret i32 %len
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define i32 @test_raw_array_length_load
; CHECK-NOT: jeandle.new_array
; CHECK: ret i32 7

!java-method-compilation = !{}
