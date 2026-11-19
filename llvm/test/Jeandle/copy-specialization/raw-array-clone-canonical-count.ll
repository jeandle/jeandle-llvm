; RUN: opt -S -verify-each -passes='instcombine,copy-specialization' -jeandle-vm-callback-log=%S/Inputs/primitive-array-clone.cblog %s | FileCheck %s

@VMOptions.ArrayCopyLoadStoreMaxElem = constant i32 0
@VMOptions.ReduceBulkZeroing = constant i1 true
@VMOptions.ReduceInitialCardMarks = constant i1 true
@arrayOopDesc.length_offset_in_bytes = constant i32 16
@arrayOopDesc.base_offset_in_bytes.long = constant i32 24
@arrayOopDesc.base_offset_in_bytes.char = constant i32 24
@arrayOopDesc.base_offset_in_bytes.object = constant i32 24
@heapOopSize = constant i32 8
@arrayOopDesc.element_size.object = constant i32 8

declare ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32, i1, i1)
declare void @jeandle.copy(ptr addrspace(1), i64, ptr addrspace(1), i64, i64, ptr, ptr, i64, i64)
declare void @StubRoutines_jlong_disjoint_arraycopy(ptr addrspace(1), ptr addrspace(1), i64)
define void @jeandle.clone_payload(ptr addrspace(1) %src, i64 %src_offset, ptr addrspace(1) %dst, i64 %dst_offset, i64 %count, i1 %instance) #2 {
  %src_start = getelementptr i8, ptr addrspace(1) %src, i64 %src_offset
  %dst_start = getelementptr i8, ptr addrspace(1) %dst, i64 %dst_offset
  call void @StubRoutines_jlong_disjoint_arraycopy(ptr addrspace(1) %src_start, ptr addrspace(1) %dst_start, i64 %count)
  ret void
}

; A raw uncompressed clone starts at the length/header word, eight bytes
; before the first element. Only the payload extent needs initialization.
define ptr addrspace(1) @dynamic_chars(ptr addrspace(1) "java-klass"="102" %src, i32 %length, i32 %size) #0 {
  %dst = call ptr addrspace(1) @jeandle.new_array(ptr null, i32 %length, i32 %size, i32 24, i32 1000, i1 false, i1 false)
  %length64 = sext i32 %length to i64
  %bytes = shl i64 %length64, 1
  %extent = add i64 %bytes, 24
  %payload = sub i64 %extent, 16
  %rounded = add i64 %payload, 7
  %words = lshr i64 %rounded, 3
  call void @jeandle.copy(ptr addrspace(1) %src, i64 16, ptr addrspace(1) %dst, i64 16, i64 %words, ptr null, ptr null, i64 %extent, i64 %extent) #1
  ret ptr addrspace(1) %dst
}

; CHECK-LABEL: define ptr addrspace(1) @dynamic_chars(
; CHECK-NEXT: %dst = call ptr addrspace(1) @jeandle.new_array({{.*}}i1 true, i1 true)
; CHECK: call hotspotcc void @jeandle.clone_payload({{.*}}i64 %words, i1 false)
; CHECK-NEXT: call hotspotcc void @jeandle.membar_allocation_init(ptr addrspace(1) %dst)

define ptr addrspace(1) @dynamic_objects(ptr addrspace(1) "java-klass"="105" %src, i32 %length, i32 %size) #0 {
  %dst = call ptr addrspace(1) @jeandle.new_array(ptr null, i32 %length, i32 %size, i32 24, i32 1000, i1 false, i1 false)
  %length64 = zext i32 %length to i64
  %bytes = shl i64 %length64, 3
  %rounded = add i64 %bytes, 15
  %words = lshr i64 %rounded, 3
  call void @jeandle.copy(ptr addrspace(1) %src, i64 16, ptr addrspace(1) %dst, i64 16, i64 %words, ptr null, ptr null, i64 0, i64 0) #1
  ret ptr addrspace(1) %dst
}

; CHECK-LABEL: define ptr addrspace(1) @dynamic_objects(
; CHECK-NEXT: %dst = call ptr addrspace(1) @jeandle.new_array({{.*}}i1 true, i1 true)
; CHECK: call hotspotcc void @jeandle.clone_payload({{.*}}i64 %words, i1 false)
; CHECK-NEXT: call hotspotcc void @jeandle.membar_allocation_init(ptr addrspace(1) %dst)

attributes #0 = { "java-method"="0" }
attributes #1 = { "jeandle.copy.kind"="clone-array" "jeandle.copy.tightly-coupled-allocation" }
attributes #2 = { nounwind "gc-leaf-function" "lower-phase"="1" }
!java-method-compilation = !{}

; Canonical 8-byte element counts must survive instcombine before specialization.
; CHECK-LABEL: define ptr addrspace(1) @canonical_longs(
; CHECK: @jeandle.new_array({{.*}}i1 true, i1 true)
; CHECK: call hotspotcc void @jeandle.clone_payload
; CHECK: call hotspotcc void @jeandle.membar_allocation_init

define ptr addrspace(1) @canonical_longs(ptr addrspace(1) "java-klass"="101" %src, i32 %length, i32 %size) #0 {
  %dst = call ptr addrspace(1) @jeandle.new_array(ptr null, i32 %length, i32 %size, i32 24, i32 1000, i1 false, i1 false)
  %words = zext i32 %length to i64
  call void @jeandle.copy(ptr addrspace(1) %src, i64 24, ptr addrspace(1) %dst, i64 24, i64 %words, ptr null, ptr null, i64 0, i64 0) #1
  ret ptr addrspace(1) %dst
}

; An eight-byte header prefix requires one extra copied word.
; CHECK-LABEL: define ptr addrspace(1) @short_wide_reference_count(
; CHECK: @jeandle.new_array({{.*}}i1 false, i1 false)
; CHECK: call hotspotcc void @jeandle.clone_payload

define ptr addrspace(1) @short_wide_reference_count(ptr addrspace(1) "java-klass"="105" %src, i32 %length, i32 %size) #0 {
  %dst = call ptr addrspace(1) @jeandle.new_array(ptr null, i32 %length, i32 %size, i32 24, i32 1000, i1 false, i1 false)
  %words = zext i32 %length to i64
  call void @jeandle.copy(ptr addrspace(1) %src, i64 16, ptr addrspace(1) %dst, i64 16, i64 %words, ptr null, ptr null, i64 0, i64 0) #1
  ret ptr addrspace(1) %dst
}

; Full coverage alone cannot bypass an intervening observation.
; CHECK-LABEL: define ptr addrspace(1) @observed_longs(
; CHECK: @jeandle.new_array({{.*}}i1 false, i1 false)
; CHECK: call void @observe
; CHECK: call hotspotcc void @jeandle.clone_payload

declare void @observe(ptr addrspace(1))
define ptr addrspace(1) @observed_longs(ptr addrspace(1) "java-klass"="101" %src, i32 %length, i32 %size) #0 {
  %dst = call ptr addrspace(1) @jeandle.new_array(ptr null, i32 %length, i32 %size, i32 24, i32 1000, i1 false, i1 false)
  call void @observe(ptr addrspace(1) %dst)
  %words = zext i32 %length to i64
  call void @jeandle.copy(ptr addrspace(1) %src, i64 24, ptr addrspace(1) %dst, i64 24, i64 %words, ptr null, ptr null, i64 0, i64 0) #1
  ret ptr addrspace(1) %dst
}

; The live JVM reaches this sext-and-mask form before CopySpecialization.
; CHECK-LABEL: define ptr addrspace(1) @masked_longs(
; CHECK: @jeandle.new_array({{.*}}i1 true, i1 true)
; CHECK: call hotspotcc void @jeandle.clone_payload
; CHECK: call hotspotcc void @jeandle.membar_allocation_init

define ptr addrspace(1) @masked_longs(ptr addrspace(1) "java-klass"="101" %src, i32 %length, i32 %size) #0 {
  %dst = call ptr addrspace(1) @jeandle.new_array(ptr null, i32 %length, i32 %size, i32 24, i32 1000, i1 false, i1 false)
  %extended = sext i32 %length to i64
  %words = and i64 %extended, 2305843009213693951
  call void @jeandle.copy(ptr addrspace(1) %src, i64 24, ptr addrspace(1) %dst, i64 24, i64 %words, ptr null, ptr null, i64 0, i64 0) #1
  ret ptr addrspace(1) %dst
}


; Drop bit 30 while retaining the i64 mask form after InstCombine.
; A mask dropping a possible positive Java length bit cannot prove coverage.
; CHECK-LABEL: define ptr addrspace(1) @insufficient_mask(
; CHECK: @jeandle.new_array({{.*}}i1 false, i1 false)
; CHECK: call hotspotcc void @jeandle.clone_payload
; CHECK: call hotspotcc void @jeandle.membar_allocation_init

define ptr addrspace(1) @insufficient_mask(ptr addrspace(1) "java-klass"="101" %src, i32 %length, i32 %size) #0 {
  %dst = call ptr addrspace(1) @jeandle.new_array(ptr null, i32 %length, i32 %size, i32 24, i32 1000, i1 false, i1 false)
  %extended = sext i32 %length to i64
  %words = and i64 %extended, 2305843008139952127
  call void @jeandle.copy(ptr addrspace(1) %src, i64 24, ptr addrspace(1) %dst, i64 24, i64 %words, ptr null, ptr null, i64 0, i64 0) #1
  ret ptr addrspace(1) %dst
}


; CHECK-LABEL: define ptr addrspace(1) @masked_wide_reference(
; CHECK: @jeandle.new_array({{.*}}i1 true, i1 true)
; CHECK: call hotspotcc void @jeandle.clone_payload
; CHECK: call hotspotcc void @jeandle.membar_allocation_init
define ptr addrspace(1) @masked_wide_reference(ptr addrspace(1) "java-klass"="105" %src, i32 %length, i32 %size) #0 {
  %dst = call ptr addrspace(1) @jeandle.new_array(ptr null, i32 %length, i32 %size, i32 24, i32 1000, i1 false, i1 false)
  %length64 = sext i32 %length to i64
  %masked = and i64 %length64, 2305843009213693951
  %words = add i64 %masked, 1
  call void @jeandle.copy(ptr addrspace(1) %src, i64 16, ptr addrspace(1) %dst, i64 16, i64 %words, ptr null, ptr null, i64 0, i64 0) #1
  ret ptr addrspace(1) %dst
}
