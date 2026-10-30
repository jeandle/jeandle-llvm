; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" -jeandle-vm-callback-log=%S/Inputs/213_arraystorecheck_unknown_value_klass.cblog %s | FileCheck %s

; Virtual Object[] (array klass 8888, element klass 4444) where the
; stored value comes from an opaque function argument with no
; java-klass attribute — getJavaType returns unknown, ValueKlass=0.
; The element klass is not java.lang.Object, so foldArrayStoreCheck bails
; conservatively: mark the array ineligible so the alloc and the surviving
; array_store_check both stay in IR.

declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32, i1, i1)
declare hotspotcc i1 @jeandle.array_store_check(ptr addrspace(1), ptr addrspace(1))

declare i32 @__gxx_personality_v0(...)

define i1 @test_storecheck_unknown(ptr addrspace(1) %v) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %arr = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
            ptr inttoptr (i64 8888 to ptr), i32 4, i32 32, i32 16, i32 1048576, i1 false, i1 false)
         to label %n unwind label %u
n:
  %r = call hotspotcc i1 @jeandle.array_store_check(ptr addrspace(1) %v,
                                                    ptr addrspace(1) %arr)
  ret i1 %r
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define i1 @test_storecheck_unknown
; CHECK: jeandle.new_array
; CHECK: jeandle.array_store_check

!java-method-compilation = !{}
