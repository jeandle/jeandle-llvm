; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" \
; RUN:   -jeandle-vm-callback-log=%S/Inputs/452_get_class_array_types.cblog \
; RUN:   %s | FileCheck %s

; PEA getClass coverage for virtual arrays.  The exact array Klass is known at
; the allocation site, so get_class can be replaced with the corresponding
; java.lang.Class mirror without materializing either array.  Keep primitive
; and object arrays separate: their Klass values must select different mirror
; oop handles (this is the part that the Java regression tests exercise).

declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32)
declare hotspotcc ptr addrspace(1) @jeandle.get_class(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define ptr addrspace(1) @test_get_class_primitive_array()
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %arr = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
      ptr inttoptr (i64 7001 to ptr), i32 4, i32 32, i32 16, i32 1048576)
      to label %body unwind label %unwind
body:
  %klass = call hotspotcc ptr addrspace(1)
      @jeandle.get_class(ptr addrspace(1) %arr)
  ret ptr addrspace(1) %klass
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

define ptr addrspace(1) @test_get_class_object_array()
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %arr = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
      ptr inttoptr (i64 7002 to ptr), i32 4, i32 64, i32 16, i32 1048576)
      to label %body unwind label %unwind
body:
  %klass = call hotspotcc ptr addrspace(1)
      @jeandle.get_class(ptr addrspace(1) %arr)
  ret ptr addrspace(1) %klass
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; The primitive array selects its own mirror handle and its allocation is gone.
; CHECK-LABEL: define ptr addrspace(1) @test_get_class_primitive_array
; CHECK-NOT: jeandle.new_array
; CHECK-NOT: jeandle.get_class
; CHECK: load ptr addrspace(1), ptr @oop_handle_PrimitiveArray_10
; CHECK: ret ptr addrspace(1)

; The object array likewise selects a distinct mirror handle and is not
; materialized merely because getClass was queried.
; CHECK-LABEL: define ptr addrspace(1) @test_get_class_object_array
; CHECK-NOT: jeandle.new_array
; CHECK-NOT: jeandle.get_class
; CHECK: load ptr addrspace(1), ptr @oop_handle_ObjectArray_11
; CHECK: ret ptr addrspace(1)

!java-method-compilation = !{}
