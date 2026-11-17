; RUN: opt -S -verify-each -passes=copy-specialization %s | FileCheck %s --check-prefixes=COMMON,REDUCE
; RUN: sed 's/@VMOptions.ReduceBulkZeroing = constant i1 true/@VMOptions.ReduceBulkZeroing = constant i1 false/' %s | opt -S -verify-each -passes=copy-specialization | FileCheck %s --check-prefixes=COMMON,KEEP
; RUN: sed '/^declare void @StubRoutines_arrayof_oop_disjoint_arraycopy_uninit/d' %s | opt -S -verify-each -passes=copy-specialization | FileCheck %s --check-prefix=MISSING
; RUN: opt -S -verify-each -passes='copy-specialization,instcombine,simplifycfg' %s | FileCheck %s --check-prefix=OPT
; RUN: sed '/^define private hotspotcc void @jeandle.zero_heap_words/,/^}/d' %s | opt -S -verify-each -passes=copy-specialization | FileCheck %s --check-prefix=NOZERO

; Transfer initialization only after PEA, with an uninterrupted allocation /
; copy interval, a nonthrowing copy, and null padding before publication.
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

define ptr addrspace(1) @full_copy(ptr addrspace(1) %src) #0 personality ptr @personality {
entry:
  %dst = call ptr addrspace(1) @jeandle.new_array(ptr null, i32 8, i32 48, i32 16, i32 1000, i1 false, i1 false)
  invoke void @jeandle.copy(ptr addrspace(1) %src, i64 0, ptr addrspace(1) %dst, i64 0, i64 8, ptr null, ptr null, i64 8, i64 8) #1 [ "deopt"(i32 0) ] to label %done unwind label %exception
done:
  ret ptr addrspace(1) %dst
exception:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; COMMON-LABEL: define ptr addrspace(1) @full_copy(
; REDUCE: @jeandle.new_array({{.*}}i1 true, i1 true)
; KEEP: @jeandle.new_array({{.*}}i1 false, i1 false)
; COMMON-NOT: @llvm.memset
; REDUCE: call void @StubRoutines_arrayof_oop_disjoint_arraycopy_uninit({{.*}}i64 8)
; KEEP: call void @StubRoutines_arrayof_oop_disjoint_arraycopy({{.*}}i64 8)
; COMMON: arraycopy.result:
; COMMON-NEXT: call hotspotcc void @jeandle.membar_allocation_init(ptr addrspace(1) %dst)
; MISSING-LABEL: define ptr addrspace(1) @full_copy(
; MISSING: @jeandle.new_array({{.*}}i1 false, i1 false)
; MISSING-NOT: @llvm.memset
; MISSING: invoke hotspotcc void @SharedRuntime_slow_arraycopy_C
; NOZERO-LABEL: define ptr addrspace(1) @full_copy(
; NOZERO: @jeandle.new_array({{.*}}i1 true, i1 true)
; NOZERO: call void @StubRoutines_arrayof_oop_disjoint_arraycopy_uninit({{.*}}i64 8)

; The i32 allocation size is not a valid byte count on the slow allocation
; path for very large arrays. Derive the tail from the Java lengths in i64.
define ptr addrspace(1) @dynamic_tail(ptr addrspace(1) %src, i32 %length, i32 %moved, i32 %size) #0 personality ptr @personality {
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

; COMMON-LABEL: define ptr addrspace(1) @dynamic_tail(
; REDUCE: @jeandle.new_array({{.*}}i1 true, i1 true)
; KEEP: @jeandle.new_array({{.*}}i1 false, i1 false)
; REDUCE: [[TAIL:%.*]] = sub i64 %length64, %moved64
; REDUCE: [[NONEMPTY:%.*]] = icmp ne i64 [[TAIL]], 0
; REDUCE-NEXT: br i1 [[NONEMPTY]], label %arraycopy.zero_tail, label %arraycopy.after_zero_tail
; REDUCE: arraycopy.zero_tail:
; REDUCE: [[START:%.*]] = shl i64 %moved64, 2
; REDUCE: [[OFFSET:%.*]] = add i64 [[START]], 16
; REDUCE: [[ALIGNED_START:%.*]] = and i64 [[OFFSET]], -8
; REDUCE: [[SIZE:%.*]] = shl i64 %length64, 2
; REDUCE: [[END:%.*]] = add i64 [[SIZE]], 23
; REDUCE: [[ALIGNED_END:%.*]] = and i64 [[END]], -8
; REDUCE: [[BYTES:%.*]] = sub i64 [[ALIGNED_END]], [[ALIGNED_START]]
; REDUCE: [[WORDS64:%.*]] = lshr i64 [[BYTES]], 3
; REDUCE: [[WORDS:%.*]] = trunc i64 [[WORDS64]] to i32
; REDUCE: [[ADDRESS:%.*]] = getelementptr i8, ptr addrspace(1) %dst, i64 [[ALIGNED_START]]
; REDUCE: call hotspotcc void @jeandle.zero_heap_words(ptr addrspace(1) align 8 [[ADDRESS]], i32 [[WORDS]])
; REDUCE-NEXT: br label %arraycopy.after_zero_tail
; REDUCE: arraycopy.after_zero_tail:
; KEEP-NOT: @llvm.memset
; COMMON: arraycopy.result:
; COMMON-NEXT: call hotspotcc void @jeandle.membar_allocation_init(ptr addrspace(1) %dst)
; NOZERO-LABEL: define ptr addrspace(1) @dynamic_tail(
; NOZERO: @jeandle.new_array({{.*}}i1 false, i1 false)
; NOZERO-NOT: @jeandle.zero_heap_words
; NOZERO-NOT: @llvm.memset
; NOZERO: call hotspotcc void @jeandle.membar_allocation_init(ptr addrspace(1) %dst)

; After normal cleanup, exact copies have an explicit edge that bypasses the
; dynamic clear. Both paths join before the copy and its publication fence.
; OPT-LABEL: define ptr addrspace(1) @dynamic_tail(
; OPT: [[EXACT:%.*]] = icmp eq i32 %length, %moved
; OPT-NEXT: br i1 [[EXACT]], label %arraycopy.after_zero_tail, label %arraycopy.zero_tail
; OPT: arraycopy.zero_tail:
; OPT: call hotspotcc void @jeandle.zero_heap_words(
; OPT-NEXT: br label %arraycopy.after_zero_tail
; OPT: arraycopy.after_zero_tail:
; OPT-NEXT: [[ZERO:%.*]] = icmp eq i32 %moved, 0
; OPT-NEXT: br i1 [[ZERO]], label %arraycopy.result, label %arraycopy.nonpositive.fast
; OPT: arraycopy.result:
; OPT-NEXT: call hotspotcc void @jeandle.membar_allocation_init(ptr addrspace(1) %dst)
; OPT-NEXT: ret ptr addrspace(1) %dst
; OPT: arraycopy.nonpositive.fast:
; OPT: call void @StubRoutines_arrayof_oop_disjoint_arraycopy_uninit(
; OPT-NEXT: br label %arraycopy.result
; OPT-LABEL: define ptr addrspace(1) @zero_copy(

define ptr addrspace(1) @zero_copy(ptr addrspace(1) %src) #0 personality ptr @personality {
entry:
  %dst = call ptr addrspace(1) @jeandle.new_array(ptr null, i32 8, i32 48, i32 16, i32 1000, i1 false, i1 false)
  invoke void @jeandle.copy(ptr addrspace(1) %src, i64 0, ptr addrspace(1) %dst, i64 0, i64 0, ptr null, ptr null, i64 0, i64 8) #1 [ "deopt"(i32 0) ] to label %done unwind label %exception
done:
  ret ptr addrspace(1) %dst
exception:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; COMMON-LABEL: define ptr addrspace(1) @zero_copy(
; REDUCE: @jeandle.new_array({{.*}}i1 true, i1 true)
; KEEP: @jeandle.new_array({{.*}}i1 false, i1 false)
; REDUCE: [[ZERO_START:%.*]] = getelementptr i8, ptr addrspace(1) %dst, i64 16
; REDUCE: call hotspotcc void @jeandle.zero_heap_words(ptr addrspace(1) align 8 [[ZERO_START]], i32 4)
; KEEP-NOT: @llvm.memset
; COMMON: arraycopy.result:
; COMMON-NEXT: call hotspotcc void @jeandle.membar_allocation_init(ptr addrspace(1) %dst)
; NOZERO-LABEL: define ptr addrspace(1) @zero_copy(
; NOZERO: @jeandle.new_array({{.*}}i1 false, i1 false)
; NOZERO-NOT: @jeandle.zero_heap_words
; NOZERO-NOT: @llvm.memset
; NOZERO: call hotspotcc void @jeandle.membar_allocation_init(ptr addrspace(1) %dst)

define ptr addrspace(1) @intervening_safepoint(ptr addrspace(1) %src) #0 personality ptr @personality {
entry:
  %dst = call ptr addrspace(1) @jeandle.new_array(ptr null, i32 8, i32 48, i32 16, i32 1000, i1 false, i1 false)
  call void @safepoint()
  invoke void @jeandle.copy(ptr addrspace(1) %src, i64 0, ptr addrspace(1) %dst, i64 0, i64 8, ptr null, ptr null, i64 8, i64 8) #1 [ "deopt"(i32 0) ] to label %done unwind label %exception
done:
  ret ptr addrspace(1) %dst
exception:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; COMMON-LABEL: define ptr addrspace(1) @intervening_safepoint(
; COMMON: @jeandle.new_array({{.*}}i1 false, i1 false)
; COMMON-NEXT: call void @safepoint()
; COMMON-NOT: @llvm.memset
; COMMON: arraycopy.result:
; COMMON-NEXT: call hotspotcc void @jeandle.membar_allocation_init(ptr addrspace(1) %dst)

; Memory effects do not imply gc-leaf-function. A call can have a safepoint
; without reading or writing the LLVM-visible Java heap.
define ptr addrspace(1) @memory_free_call(ptr addrspace(1) %src) #0 personality ptr @personality {
entry:
  %dst = call ptr addrspace(1) @jeandle.new_array(ptr null, i32 8, i32 48, i32 16, i32 1000, i1 false, i1 false)
  call void @memory_free_safepoint()
  invoke void @jeandle.copy(ptr addrspace(1) %src, i64 0, ptr addrspace(1) %dst, i64 0, i64 8, ptr null, ptr null, i64 8, i64 8) #1 [ "deopt"(i32 0) ] to label %done unwind label %exception
done:
  ret ptr addrspace(1) %dst
exception:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; COMMON-LABEL: define ptr addrspace(1) @memory_free_call(
; COMMON: @jeandle.new_array({{.*}}i1 false, i1 false)
; COMMON-NEXT: call void @memory_free_safepoint()
; COMMON-NOT: @llvm.memset
; COMMON: arraycopy.result:
; COMMON-NEXT: call hotspotcc void @jeandle.membar_allocation_init(ptr addrspace(1) %dst)

define ptr addrspace(1) @checked_copy(ptr addrspace(1) %src, ptr %src_klass, ptr %dst_klass) #0 personality ptr @personality {
entry:
  %dst = call ptr addrspace(1) @jeandle.new_array(ptr null, i32 8, i32 48, i32 16, i32 1000, i1 false, i1 false)
  invoke void @jeandle.copy(ptr addrspace(1) %src, i64 0, ptr addrspace(1) %dst, i64 0, i64 8, ptr %src_klass, ptr %dst_klass, i64 8, i64 8) #3 [ "deopt"(i32 0) ] to label %done unwind label %exception
done:
  ret ptr addrspace(1) %dst
exception:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; COMMON-LABEL: define ptr addrspace(1) @checked_copy(
; COMMON: @jeandle.new_array({{.*}}i1 false, i1 false)
; COMMON-NOT: @llvm.memset
; COMMON: invoke hotspotcc void @SharedRuntime_slow_arraycopy_C

define ptr addrspace(1) @reference_clone(ptr addrspace(1) %src, i32 %length) #0 personality ptr @personality {
entry:
  %dst = call ptr addrspace(1) @jeandle.new_array(ptr null, i32 %length, i32 48, i32 16, i32 1000, i1 false, i1 false)
  %length64 = sext i32 %length to i64
  invoke void @jeandle.copy(ptr addrspace(1) %src, i64 0, ptr addrspace(1) %dst, i64 0, i64 %length64, ptr null, ptr null, i64 %length64, i64 %length64) #4 [ "deopt"(i32 0) ] to label %done unwind label %exception
done:
  ret ptr addrspace(1) %dst
exception:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; COMMON-LABEL: define ptr addrspace(1) @reference_clone(
; REDUCE: @jeandle.new_array({{.*}}i1 true, i1 true)
; KEEP: @jeandle.new_array({{.*}}i1 false, i1 false)
; COMMON-NOT: @llvm.memset
; COMMON: arraycopy.result:
; COMMON-NEXT: call hotspotcc void @jeandle.membar_allocation_init(ptr addrspace(1) %dst)
; NOZERO-LABEL: define ptr addrspace(1) @reference_clone(
; NOZERO: @jeandle.new_array({{.*}}i1 true, i1 true)
; NOZERO: call hotspotcc void @jeandle.membar_allocation_init(ptr addrspace(1) %dst)

define ptr addrspace(1) @zero_extended_length(ptr addrspace(1) %src, i32 %length) #0 personality ptr @personality {
entry:
  %dst = call ptr addrspace(1) @jeandle.new_array(ptr null, i32 %length, i32 48, i32 16, i32 1000, i1 false, i1 false)
  %length64 = zext i32 %length to i64
  invoke void @jeandle.copy(ptr addrspace(1) %src, i64 0, ptr addrspace(1) %dst, i64 0, i64 %length64, ptr null, ptr null, i64 %length64, i64 %length64) #4 [ "deopt"(i32 0) ] to label %done unwind label %exception
done:
  ret ptr addrspace(1) %dst
exception:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; COMMON-LABEL: define ptr addrspace(1) @zero_extended_length(
; REDUCE: @jeandle.new_array({{.*}}i1 true, i1 true)
; KEEP: @jeandle.new_array({{.*}}i1 false, i1 false)
; COMMON-NOT: @llvm.memset
; COMMON: arraycopy.result:
; COMMON-NEXT: call hotspotcc void @jeandle.membar_allocation_init(ptr addrspace(1) %dst)

define ptr addrspace(1) @published_before_copy(ptr addrspace(1) %src, ptr %escape) #0 personality ptr @personality {
entry:
  %dst = call ptr addrspace(1) @jeandle.new_array(ptr null, i32 8, i32 48, i32 16, i32 1000, i1 false, i1 false)
  store ptr addrspace(1) %dst, ptr %escape
  invoke void @jeandle.copy(ptr addrspace(1) %src, i64 0, ptr addrspace(1) %dst, i64 0, i64 8, ptr null, ptr null, i64 8, i64 8) #1 [ "deopt"(i32 0) ] to label %done unwind label %exception
done:
  ret ptr addrspace(1) %dst
exception:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; COMMON-LABEL: define ptr addrspace(1) @published_before_copy(
; COMMON: @jeandle.new_array({{.*}}i1 false, i1 false)
; COMMON-NEXT: store ptr addrspace(1) %dst, ptr %escape
; COMMON-NOT: @llvm.memset
; COMMON: arraycopy.result:
; COMMON-NEXT: call hotspotcc void @jeandle.membar_allocation_init(ptr addrspace(1) %dst)

define ptr addrspace(1) @negative_copy_length(ptr addrspace(1) %src) #0 personality ptr @personality {
entry:
  %dst = call ptr addrspace(1) @jeandle.new_array(ptr null, i32 8, i32 48, i32 16, i32 1000, i1 false, i1 false)
  invoke void @jeandle.copy(ptr addrspace(1) %src, i64 0, ptr addrspace(1) %dst, i64 0, i64 -1, ptr null, ptr null, i64 8, i64 8) #5 [ "deopt"(i32 0) ] to label %done unwind label %exception
done:
  ret ptr addrspace(1) %dst
exception:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; COMMON-LABEL: define ptr addrspace(1) @negative_copy_length(
; COMMON: @jeandle.new_array({{.*}}i1 false, i1 false)
; COMMON-NOT: @llvm.memset
; COMMON: invoke hotspotcc void @SharedRuntime_slow_arraycopy_C

define ptr addrspace(1) @different_destination_length(ptr addrspace(1) %src) #0 personality ptr @personality {
entry:
  %dst = call ptr addrspace(1) @jeandle.new_array(ptr null, i32 8, i32 48, i32 16, i32 1000, i1 false, i1 false)
  invoke void @jeandle.copy(ptr addrspace(1) %src, i64 0, ptr addrspace(1) %dst, i64 0, i64 4, ptr null, ptr null, i64 8, i64 4) #1 [ "deopt"(i32 0) ] to label %done unwind label %exception
done:
  ret ptr addrspace(1) %dst
exception:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; COMMON-LABEL: define ptr addrspace(1) @different_destination_length(
; COMMON: @jeandle.new_array({{.*}}i1 false, i1 false)
; COMMON-NOT: @llvm.memset
; COMMON: arraycopy.result:
; COMMON-NEXT: call hotspotcc void @jeandle.membar_allocation_init(ptr addrspace(1) %dst)

attributes #0 = { "java-method"="0" }
attributes #1 = { "jeandle.copy.kind"="copyof" "jeandle.copy.validated" "jeandle.copy.negative-length-guard" "jeandle.copy.tightly-coupled-allocation" }
attributes #2 = { "jeandle.copy.kind"="copyof-range" "jeandle.copy.validated" "jeandle.copy.negative-length-guard" "jeandle.copy.tightly-coupled-allocation" }
attributes #3 = { "jeandle.copy.kind"="copyof" "jeandle.copy.negative-length-guard" "jeandle.copy.tightly-coupled-allocation" }
attributes #4 = { "jeandle.copy.kind"="clone-reference-array" "jeandle.copy.negative-length-guard" "jeandle.copy.tightly-coupled-allocation" }
attributes #5 = { "jeandle.copy.kind"="copyof" "jeandle.copy.validated" "jeandle.copy.tightly-coupled-allocation" }

!java-method-compilation = !{}
!current-thread = !{!0}
!0 = !{!"r15"}
