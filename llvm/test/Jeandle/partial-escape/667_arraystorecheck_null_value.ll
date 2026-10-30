; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" -jeandle-vm-callback-log=%S/Inputs/667_arraystorecheck_null_value.cblog %s | FileCheck %s

; A null value can be stored into any Object[] — the store check always
; passes, so it is eliminated (an array store of a always-null value needs no
; check). Without the elision, the unknown value klass
; would force the whole virtual array to materialize.

declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32, i1, i1)
declare hotspotcc i1 @jeandle.array_store_check(ptr addrspace(1), ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define i1 @test_storecheck_null() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %arr = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
            ptr inttoptr (i64 8888 to ptr), i32 4, i32 32, i32 16, i32 1048576, i1 false, i1 false)
         to label %n1 unwind label %u
n1:
  %r = call hotspotcc i1 @jeandle.array_store_check(
           ptr addrspace(1) null, ptr addrspace(1) %arr)
  ret i1 %r
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; The check is elided and the virtual array is NOT materialized.
; CHECK-LABEL: define i1 @test_storecheck_null
; CHECK-NOT: jeandle.new_array
; CHECK-NOT: jeandle.array_store_check
; CHECK: ret i1 true

!java-method-compilation = !{}
