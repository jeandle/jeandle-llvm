; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" -jeandle-vm-callback-log=%S/Inputs/230_value_based_check_non_value_based.cblog %s | FileCheck %s

; Virtual receiver of jeandle.check_if_value_based whose exact klass
; (4444) is NOT a value-based class. foldCheckIfValueBased queries
; IsValueBased(4444) = false and folds the call to constant `i1 false`.
; With no other use of the virtual, the allocation is fully eliminated.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare hotspotcc i1 @jeandle.check_if_value_based(ptr addrspace(1))

declare i32 @__gxx_personality_v0(...)

define i1 @test_value_based_non_vb() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 4444 to ptr), i32 16, i1 false)
       to label %n unwind label %u
n:
  %r = call hotspotcc i1 @jeandle.check_if_value_based(ptr addrspace(1) %o)
  ret i1 %r
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define i1 @test_value_based_non_vb
; CHECK-NOT: jeandle.new_instance
; CHECK-NOT: jeandle.check_if_value_based
; CHECK: ret i1 false

!java-method-compilation = !{}
