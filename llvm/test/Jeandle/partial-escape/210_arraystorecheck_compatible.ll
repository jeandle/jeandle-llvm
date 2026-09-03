; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" -jeandle-vm-callback-log=%S/Inputs/210_arraystorecheck_compatible.cblog %s | FileCheck %s

; Virtual Object[] (array klass 8888, element klass 4444) plus a
; virtual instance value whose exact klass (5555) is a subtype of the
; array's element klass. foldArrayStoreCheck queries
; ArrayElementKlass(8888)=4444, then evalSubtypeRelation calls
; IsSubtype(5555, 4444)=true and folds the check call to true. Both
; allocations are otherwise unused, so the alloc, the value alloc and
; the check call all disappear.

declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32)
declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare hotspotcc i1 @jeandle.array_store_check(ptr addrspace(1), ptr addrspace(1))

declare i32 @__gxx_personality_v0(...)

define i1 @test_storecheck_compat() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %arr = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
            ptr inttoptr (i64 8888 to ptr), i32 4, i32 32, i32 16, i32 1048576)
         to label %n1 unwind label %u
n1:
  %v = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 5555 to ptr), i32 16, i1 false)
       to label %n2 unwind label %u
n2:
  %r = call hotspotcc i1 @jeandle.array_store_check(ptr addrspace(1) %v,
                                                    ptr addrspace(1) %arr)
  ret i1 %r
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define i1 @test_storecheck_compat
; CHECK-NOT: jeandle.new_array
; CHECK-NOT: jeandle.new_instance
; CHECK-NOT: jeandle.array_store_check
; CHECK: ret i1 true

!java-method-compilation = !{}
