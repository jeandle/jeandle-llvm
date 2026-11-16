; RUN: opt -S -verify-each -passes='copy-specialization' %s | FileCheck %s --check-prefix=JAVAOP
; RUN: opt -S -verify-each -passes='function(copy-specialization),java-operation-lower<phase=1>' %s | FileCheck %s --check-prefix=LOWERED

; Copy publication remains receiver-owned until phase 1.
@WordSize = constant i64 8
@heapOopSize = constant i32 4
@personality = global ptr null
declare void @jeandle.copy(ptr addrspace(1), i64, ptr addrspace(1), i64, i64, ptr, ptr, i64, i64)
declare void @StubRoutines_arrayof_oop_disjoint_arraycopy(ptr addrspace(1), ptr addrspace(1), i64)
declare hotspotcc void @SharedRuntime_slow_arraycopy_C(ptr addrspace(1), i32, ptr addrspace(1), i32, i32, ptr)

define hotspotcc void @jeandle.membar_storestore() #1 {
  fence release
  ret void
}

define void @clone_oop_array(ptr addrspace(1) %src, ptr addrspace(1) %dest) #0 personality ptr @personality {
entry:
  invoke void @jeandle.copy(ptr addrspace(1) %src, i64 0, ptr addrspace(1) %dest, i64 0, i64 8, ptr null, ptr null, i64 8, i64 8) #2 [ "deopt"(i32 0) ] to label %normal unwind label %exception
normal:
  ret void
exception:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; JAVAOP-LABEL: define void @clone_oop_array(
; JAVAOP-NOT: fence
; JAVAOP: call void @StubRoutines_arrayof_oop_disjoint_arraycopy
; JAVAOP-NOT: @jeandle.membar_storestore
; JAVAOP-NOT: fence
; JAVAOP: arraycopy.result:
; JAVAOP-NEXT: call hotspotcc void @jeandle.membar_allocation_init(ptr addrspace(1) %dest)
; JAVAOP-NEXT: br label %normal
; JAVAOP-NOT: fence

; LOWERED-LABEL: define void @clone_oop_array(
; LOWERED: arraycopy.result:
; LOWERED-NEXT: fence release
; LOWERED-NEXT: br label %normal
; LOWERED-NOT: @jeandle.membar_storestore
; LOWERED-NOT: fence

attributes #0 = { "java-method"="0" }
attributes #1 = { noinline nounwind "gc-leaf-function" "lower-phase"="1" }
attributes #2 = { "jeandle.copy.kind"="clone-reference-array" }
!java-method-compilation = !{}
!current-thread = !{!0}
!0 = !{!"r15"}
