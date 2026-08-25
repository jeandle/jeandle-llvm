; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; PEA: jeandle.load_klass on a virtual instance folds to the
; allocation's compile-time klass constant (in addrspace 0).

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare hotspotcc ptr addrspace(0) @jeandle.load_klass(ptr addrspace(1))

declare i32 @__gxx_personality_v0(...)

define ptr addrspace(0) @test_load_klass() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
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

; CHECK-LABEL: define ptr @test_load_klass
; CHECK-NOT: jeandle.new_instance
; CHECK-NOT: jeandle.load_klass
; CHECK: ret ptr inttoptr (i64 12345 to ptr)

!java-method-compilation = !{}
