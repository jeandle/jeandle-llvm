; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" -jeandle-vm-callback-log=%S/Inputs/687_arraystorecheck_object_element_unknown_value.cblog %s | FileCheck %s

; A store into an exact Object[] never needs a covariant array-store check:
; every non-null Java reference is a subtype of java.lang.Object. The stored
; value deliberately has no klass metadata, so this exercises the Object
; element fast path rather than the general subtype query.

declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32, i1, i1)
declare hotspotcc i1 @jeandle.array_store_check(ptr addrspace(1), ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define i1 @object_array_unknown_value(ptr addrspace(1) %value) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %array = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
             ptr inttoptr (i64 8888 to ptr), i32 4, i32 32, i32 16,
             i32 1048576, i1 false, i1 false)
           to label %body unwind label %unwind
body:
  %checked = call hotspotcc i1 @jeandle.array_store_check(
      ptr addrspace(1) %value, ptr addrspace(1) %array)
  ret i1 %checked
unwind:
  %landing = landingpad i64 cleanup
  resume i64 %landing
}

; CHECK-LABEL: define i1 @object_array_unknown_value
; CHECK-NOT: jeandle.new_array
; CHECK-NOT: jeandle.array_store_check
; CHECK: ret i1 true

!java-method-compilation = !{}
