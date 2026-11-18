; RUN: split-file %s %t
; RUN: cat %t/common.ll %t/helper.ll | opt -S -verify-each -passes=copy-specialization | FileCheck %s --check-prefixes=GOOD,COMPRESSED
; RUN: cat %t/common.ll %t/helper.ll | sed 's/@ObjectAlignmentInBytes = constant i32 16/@ObjectAlignmentInBytes = constant i32 32/' | opt -S -verify-each -passes=copy-specialization | FileCheck %s --check-prefixes=GOOD,COMPRESSED
; RUN: cat %t/common.ll %t/helper.ll | sed 's/@arrayOopDesc.element_size.object = constant i32 4/@arrayOopDesc.element_size.object = constant i32 8/; s/i32 64, i32 24/i32 80, i32 24/' | opt -S -verify-each -passes=copy-specialization | FileCheck %s --check-prefixes=GOOD,WIDE
; RUN: cat %t/common.ll %t/helper.ll | sed 's/@arrayOopDesc.element_size.object = constant i32 4/@arrayOopDesc.element_size.object = constant i32 8/; s/@ObjectAlignmentInBytes = constant i32 16/@ObjectAlignmentInBytes = constant i32 32/; s/i32 64, i32 24/i32 96, i32 24/' | opt -S -verify-each -passes=copy-specialization | FileCheck %s --check-prefixes=GOOD,WIDE
; RUN: opt -S -verify-each -passes=copy-specialization %t/common.ll | FileCheck %s --check-prefix=KEEP
; RUN: cat %t/common.ll %t/declaration.ll | opt -S -verify-each -passes=copy-specialization | FileCheck %s --check-prefix=KEEP
; RUN: cat %t/common.ll %t/return-type.ll | opt -S -verify-each -passes=copy-specialization | FileCheck %s --check-prefix=KEEP
; RUN: cat %t/common.ll %t/helper.ll | sed 's/hotspotcc void @jeandle.zero_heap_words/void @jeandle.zero_heap_words/' | opt -S -verify-each -passes=copy-specialization | FileCheck %s --check-prefix=KEEP
; RUN: cat %t/common.ll %t/helper.ll | sed 's/ nounwind / /' | opt -S -verify-each -passes=copy-specialization | FileCheck %s --check-prefix=KEEP
; RUN: cat %t/common.ll %t/helper.ll | sed 's/ "gc-leaf-function"/ /' | opt -S -verify-each -passes=copy-specialization | FileCheck %s --check-prefix=KEEP
; RUN: cat %t/common.ll %t/helper.ll | sed 's/"lower-phase"="1"/"lower-phase"="2"/' | opt -S -verify-each -passes=copy-specialization | FileCheck %s --check-prefix=KEEP
; RUN: cat %t/common.ll %t/helper.ll | sed 's/ "lower-phase"="1"/ /' | opt -S -verify-each -passes=copy-specialization | FileCheck %s --check-prefix=KEEP
; RUN: cat %t/common.ll %t/helper.ll | sed 's/i32 %words/i64 %words/' | opt -S -verify-each -passes=copy-specialization | FileCheck %s --check-prefix=KEEP
; RUN: cat %t/common.ll %t/helper.ll | sed 's/ptr addrspace(1) align 8 %base/ptr align 8 %base/' | opt -S -verify-each -passes=copy-specialization | FileCheck %s --check-prefix=KEEP
; RUN: cat %t/common.ll %t/helper.ll | sed 's/align 8 %base/align 4 %base/' | opt -S -verify-each -passes=copy-specialization | FileCheck %s --check-prefix=KEEP
; RUN: cat %t/common.ll %t/helper.ll | sed 's/i32 %words)/i32 %words, ...)/' | opt -S -verify-each -passes=copy-specialization | FileCheck %s --check-prefix=KEEP
; RUN: cat %t/common.ll %t/helper.ll | sed 's/@arrayOopDesc.base_offset_in_bytes.object = constant i32 24/@arrayOopDesc.base_offset_in_bytes.object = constant i32 20/' | opt -S -verify-each -passes=copy-specialization | FileCheck %s --check-prefix=KEEP
; RUN: cat %t/common.ll %t/helper.ll | sed 's/@arrayOopDesc.element_size.object = constant i32 4/@arrayOopDesc.element_size.object = constant i32 2/' | opt -S -verify-each -passes=copy-specialization | FileCheck %s --check-prefix=KEEP

; Word rounding can clear one preceding compressed oop, which the leaf copy
; overwrites before observation. The allocation clears through its own size,
; including any 16/32-byte object-alignment padding, only on the fast path.
; GOOD-LABEL: define ptr addrspace(1) @odd_copied_prefix(
; COMPRESSED: @jeandle.new_array({{.*}}i32 32, i32 1000, i1 false, i1 true)
; WIDE: @jeandle.new_array({{.*}}i32 48, i32 1000, i1 false, i1 true)
; GOOD-NOT: call hotspotcc void @jeandle.zero_heap_words
; GOOD: call void @StubRoutines_arrayof_oop_disjoint_arraycopy_uninit({{.*}}i64 3)
; GOOD: call hotspotcc void @jeandle.membar_allocation_init(ptr addrspace(1) %dst)
; KEEP-LABEL: define ptr addrspace(1) @odd_copied_prefix(
; KEEP: @jeandle.new_array({{.*}}i1 false, i1 false)
; KEEP-NOT: call hotspotcc void @jeandle.zero_heap_words
; KEEP: call hotspotcc void @jeandle.membar_allocation_init(ptr addrspace(1) %dst)

; Very large arrays must take the runtime path, which ignores clear-start.
; Neither a full tail nor a short tail is cleared again after allocation.
; GOOD-LABEL: define ptr addrspace(1) @largest_zero_copy(
; GOOD: [[START:%.*]] = select i1 false, i32 %fast_size, i32 24
; GOOD: @jeandle.new_array({{.*}}i32 [[START]], i32 1000, i1 false, i1 true)
; GOOD-NOT: call hotspotcc void @jeandle.zero_heap_words
; GOOD: call hotspotcc void @jeandle.membar_allocation_init(ptr addrspace(1) %dst)
; KEEP-LABEL: define ptr addrspace(1) @largest_zero_copy(
; KEEP: @jeandle.new_array({{.*}}i1 false, i1 false)
; KEEP-NOT: call hotspotcc void @jeandle.zero_heap_words
; KEEP: call hotspotcc void @jeandle.membar_allocation_init(ptr addrspace(1) %dst)

; GOOD-LABEL: define ptr addrspace(1) @largest_short_tail(
; COMPRESSED: [[TAIL:%.*]] = select i1 false, i32 %fast_size, i32 16
; COMPRESSED: @jeandle.new_array({{.*}}i32 [[TAIL]], i32 1000, i1 false, i1 true)
; WIDE: [[TAIL:%.*]] = select i1 false, i32 %fast_size, i32 8
; WIDE: @jeandle.new_array({{.*}}i32 [[TAIL]], i32 1000, i1 false, i1 true)
; GOOD-NOT: call hotspotcc void @jeandle.zero_heap_words
; GOOD: call void @StubRoutines_arrayof_oop_disjoint_arraycopy_uninit({{.*}}i64 2147483646)
; GOOD: call hotspotcc void @jeandle.membar_allocation_init(ptr addrspace(1) %dst)
; KEEP-LABEL: define ptr addrspace(1) @largest_short_tail(
; KEEP: @jeandle.new_array({{.*}}i1 false, i1 false)
; KEEP-NOT: call hotspotcc void @jeandle.zero_heap_words
; KEEP: call hotspotcc void @jeandle.membar_allocation_init(ptr addrspace(1) %dst)

;--- common.ll
@VMOptions.ReduceBulkZeroing = constant i1 true
@VMOptions.ArrayCopyLoadStoreMaxElem = constant i32 0
@arrayOopDesc.base_offset_in_bytes.object = constant i32 24
@arrayOopDesc.element_size.object = constant i32 4
@ObjectAlignmentInBytes = constant i32 16
@WordSize = constant i64 8
@personality = global ptr null

declare ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32, i1, i1)
declare void @jeandle.copy(ptr addrspace(1), i64, ptr addrspace(1), i64, i64, ptr, ptr, i64, i64)
declare void @StubRoutines_arrayof_oop_disjoint_arraycopy_uninit(ptr addrspace(1), ptr addrspace(1), i64)
declare hotspotcc void @SharedRuntime_slow_arraycopy_C(ptr addrspace(1), i32, ptr addrspace(1), i32, i32, ptr)
declare i1 @jeandle.check_klass_subtype(ptr, ptr)
declare ptr @jeandle.load_array_element_klass(ptr)

define ptr addrspace(1) @odd_copied_prefix(ptr addrspace(1) %src) #0 personality ptr @personality {
  %dst = call ptr addrspace(1) @jeandle.new_array(ptr null, i32 7, i32 64, i32 24, i32 1000, i1 false, i1 false)
  invoke void @jeandle.copy(ptr addrspace(1) %src, i64 0, ptr addrspace(1) %dst, i64 0, i64 3, ptr null, ptr null, i64 3, i64 7) #1 [ "deopt"(i32 0) ] to label %done unwind label %exception
done:
  ret ptr addrspace(1) %dst
exception:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

define ptr addrspace(1) @largest_zero_copy(ptr addrspace(1) %src, i32 %fast_size) #0 personality ptr @personality {
  %dst = call ptr addrspace(1) @jeandle.new_array(ptr null, i32 2147483647, i32 %fast_size, i32 24, i32 1000, i1 false, i1 false)
  invoke void @jeandle.copy(ptr addrspace(1) %src, i64 0, ptr addrspace(1) %dst, i64 0, i64 0, ptr null, ptr null, i64 0, i64 2147483647) #1 [ "deopt"(i32 0) ] to label %done unwind label %exception
done:
  ret ptr addrspace(1) %dst
exception:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

define ptr addrspace(1) @largest_short_tail(ptr addrspace(1) %src, i32 %fast_size) #0 personality ptr @personality {
  %dst = call ptr addrspace(1) @jeandle.new_array(ptr null, i32 2147483647, i32 %fast_size, i32 24, i32 1000, i1 false, i1 false)
  invoke void @jeandle.copy(ptr addrspace(1) %src, i64 0, ptr addrspace(1) %dst, i64 0, i64 2147483646, ptr null, ptr null, i64 2147483646, i64 2147483647) #1 [ "deopt"(i32 0) ] to label %done unwind label %exception
done:
  ret ptr addrspace(1) %dst
exception:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

attributes #0 = { "java-method"="0" }
attributes #1 = { "jeandle.copy.kind"="copyof-range" "jeandle.copy.validated" "jeandle.copy.negative-length-guard" "jeandle.copy.tightly-coupled-allocation" }
!java-method-compilation = !{}
!current-thread = !{!0}
!0 = !{!"r15"}

;--- helper.ll
define private hotspotcc void @jeandle.zero_heap_words(ptr addrspace(1) align 8 %base, i32 %words) nounwind "gc-leaf-function" "lower-phase"="1" {
  ret void
}

;--- declaration.ll
declare hotspotcc void @jeandle.zero_heap_words(ptr addrspace(1) align 8, i32) nounwind "gc-leaf-function" "lower-phase"="1"

;--- return-type.ll
define private hotspotcc i64 @jeandle.zero_heap_words(ptr addrspace(1) align 8 %base, i32 %words) nounwind "gc-leaf-function" "lower-phase"="1" {
  ret i64 0
}
