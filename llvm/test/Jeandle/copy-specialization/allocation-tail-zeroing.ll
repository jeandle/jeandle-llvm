; RUN: opt -S -verify-each -passes=copy-specialization %s | FileCheck %s

@VMOptions.ReduceBulkZeroing = constant i1 true
@VMOptions.ArrayCopyLoadStoreMaxElem = constant i32 0
@heapOopSize = constant i32 4
@WordSize = constant i64 8
@personality = global ptr null

declare ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32, i1, i1)
declare void @jeandle.copy(ptr addrspace(1), i64, ptr addrspace(1), i64, i64, ptr, ptr, i64, i64)
declare void @StubRoutines_arrayof_oop_disjoint_arraycopy_uninit(ptr addrspace(1), ptr addrspace(1), i64)
declare void @StubRoutines_arrayof_oop_disjoint_arraycopy(ptr addrspace(1), ptr addrspace(1), i64)
declare hotspotcc void @SharedRuntime_slow_arraycopy_C(ptr addrspace(1), i32, ptr addrspace(1), i32, i32, ptr)
declare i1 @jeandle.check_klass_subtype(ptr, ptr)
declare ptr @jeandle.load_array_element_klass(ptr)
declare void @safepoint()
declare void @memory_free_safepoint() nounwind willreturn memory(none)

define private hotspotcc void @jeandle.zero_heap_words(ptr addrspace(1) align 8 %base, i32 %words) nounwind "gc-leaf-function" "lower-phase"="1" {
  ret void
}

; CHECK-LABEL: define ptr addrspace(1) @constant_tail(
; CHECK: @jeandle.new_array(ptr null, i32 8, i32 48, i32 24, i32 1000, i1 false, i1 true)
; CHECK-NOT: call hotspotcc void @jeandle.zero_heap_words
; CHECK: call hotspotcc void @jeandle.membar_allocation_init
define ptr addrspace(1) @constant_tail(ptr addrspace(1) %src, i32 %length, i32 %moved, i32 %size, ptr %prefix) #0 personality ptr @personality {
entry:
  %dst = invoke ptr addrspace(1) @jeandle.new_array(ptr null, i32 8, i32 48, i32 16, i32 1000, i1 false, i1 false) to label %copy unwind label %exception
copy:
  invoke void @jeandle.copy(ptr addrspace(1) %src, i64 0, ptr addrspace(1) %dst, i64 0, i64 3, ptr null, ptr null, i64 3, i64 8) #2 [ "deopt"(i32 0) ] to label %done unwind label %exception
done:
  ret ptr addrspace(1) %dst
exception:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define ptr addrspace(1) @dynamic_tail(
; CHECK: [[EXACT:%.*]] = icmp eq i32 %moved, %length
; CHECK: [[START:%.*]] = select i1 [[EXACT]], i32 %size, i32 {{%.*}}
; CHECK: @jeandle.new_array(ptr null, i32 %length, i32 %size, i32 [[START]], i32 1000, i1 false, i1 true)
; CHECK-NOT: call hotspotcc void @jeandle.zero_heap_words
; CHECK: call hotspotcc void @jeandle.membar_allocation_init
define ptr addrspace(1) @dynamic_tail(ptr addrspace(1) %src, i32 %length, i32 %moved, i32 %size, ptr %prefix) #0 personality ptr @personality {
entry:
  %dst = invoke ptr addrspace(1) @jeandle.new_array(ptr null, i32 %length, i32 %size, i32 16, i32 1000, i1 false, i1 false) to label %copy unwind label %exception
copy:
  %length64 = sext i32 %length to i64
  %moved64 = sext i32 %moved to i64
  invoke void @jeandle.copy(ptr addrspace(1) %src, i64 0, ptr addrspace(1) %dst, i64 0, i64 %moved64, ptr null, ptr null, i64 %moved64, i64 %length64) #2 [ "deopt"(i32 0) ] to label %done unwind label %exception
done:
  ret ptr addrspace(1) %dst
exception:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define ptr addrspace(1) @unavailable_prefix(
; CHECK: @jeandle.new_array({{.*}}i32 16, i32 1000, i1 false, i1 false)
; CHECK: load i32, ptr %prefix
; CHECK-NOT: call hotspotcc void @jeandle.zero_heap_words
; CHECK: call hotspotcc void @jeandle.membar_allocation_init
define ptr addrspace(1) @unavailable_prefix(ptr addrspace(1) %src, i32 %length, i32 %moved, i32 %size, ptr %prefix) #0 personality ptr @personality {
entry:
  %dst = invoke ptr addrspace(1) @jeandle.new_array(ptr null, i32 %length, i32 %size, i32 16, i32 1000, i1 false, i1 false) to label %copy unwind label %exception
copy:
  %length64 = sext i32 %length to i64
  %late = load i32, ptr %prefix
  %moved64 = sext i32 %late to i64
  invoke void @jeandle.copy(ptr addrspace(1) %src, i64 0, ptr addrspace(1) %dst, i64 0, i64 %moved64, ptr null, ptr null, i64 %moved64, i64 %length64) #2 [ "deopt"(i32 0) ] to label %done unwind label %exception
done:
  ret ptr addrspace(1) %dst
exception:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define ptr addrspace(1) @late_arithmetic_prefix(
; CHECK: @jeandle.new_array({{.*}}i32 16, i32 1000, i1 false, i1 false)
; CHECK: %late = and i32 %moved, 7
; CHECK-NOT: call hotspotcc void @jeandle.zero_heap_words
; CHECK: call hotspotcc void @jeandle.membar_allocation_init
define ptr addrspace(1) @late_arithmetic_prefix(ptr addrspace(1) %src, i32 %length, i32 %moved, i32 %size, ptr %prefix) #0 personality ptr @personality {
entry:
  %dst = invoke ptr addrspace(1) @jeandle.new_array(ptr null, i32 8, i32 48, i32 16, i32 1000, i1 false, i1 false) to label %copy unwind label %exception
copy:
  %length64 = sext i32 %length to i64
  %late = and i32 %moved, 7
  %moved64 = sext i32 %late to i64
  invoke void @jeandle.copy(ptr addrspace(1) %src, i64 0, ptr addrspace(1) %dst, i64 0, i64 %moved64, ptr null, ptr null, i64 %moved64, i64 8) #2 [ "deopt"(i32 0) ] to label %done unwind label %exception
done:
  ret ptr addrspace(1) %dst
exception:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define ptr addrspace(1) @zero_prefix(
; CHECK: @jeandle.new_array(ptr null, i32 8, i32 48, i32 16, i32 1000, i1 false, i1 true)
; CHECK-NOT: call hotspotcc void @jeandle.zero_heap_words
; CHECK: call hotspotcc void @jeandle.membar_allocation_init
define ptr addrspace(1) @zero_prefix(ptr addrspace(1) %src, i32 %length, i32 %moved, i32 %size, ptr %prefix) #0 personality ptr @personality {
entry:
  %dst = invoke ptr addrspace(1) @jeandle.new_array(ptr null, i32 8, i32 48, i32 16, i32 1000, i1 false, i1 false) to label %copy unwind label %exception
copy:
  invoke void @jeandle.copy(ptr addrspace(1) %src, i64 0, ptr addrspace(1) %dst, i64 0, i64 0, ptr null, ptr null, i64 0, i64 8) #2 [ "deopt"(i32 0) ] to label %done unwind label %exception
done:
  ret ptr addrspace(1) %dst
exception:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

attributes #0 = { "java-method"="0" }
attributes #1 = { "jeandle.copy.kind"="copyof" "jeandle.copy.validated" "jeandle.copy.negative-length-guard" "jeandle.copy.tightly-coupled-allocation" }
attributes #2 = { "jeandle.copy.kind"="copyof-range" "jeandle.copy.validated" "jeandle.copy.negative-length-guard" "jeandle.copy.tightly-coupled-allocation" }
attributes #3 = { "jeandle.copy.kind"="copyof" "jeandle.copy.negative-length-guard" "jeandle.copy.tightly-coupled-allocation" }
attributes #4 = { "jeandle.copy.kind"="clone-reference-array" "jeandle.copy.negative-length-guard" "jeandle.copy.tightly-coupled-allocation" }
attributes #5 = { "jeandle.copy.kind"="copyof" "jeandle.copy.validated" "jeandle.copy.tightly-coupled-allocation" }

!java-method-compilation = !{}
!current-thread = !{!0}
!0 = !{!"r15"}
