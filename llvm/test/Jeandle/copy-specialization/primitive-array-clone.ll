; RUN: opt -S -verify-each -passes=copy-specialization -jeandle-vm-callback-log=%S/Inputs/primitive-array-clone.cblog %s | FileCheck %s --check-prefixes=COMMON,REDUCE
; RUN: sed 's/@VMOptions.ReduceBulkZeroing = constant i1 true/@VMOptions.ReduceBulkZeroing = constant i1 false/' %s | opt -S -verify-each -passes=copy-specialization -jeandle-vm-callback-log=%S/Inputs/primitive-array-clone.cblog | FileCheck %s --check-prefixes=COMMON,KEEP

@VMOptions.ArrayCopyLoadStoreMaxElem = constant i32 8
@VMOptions.ReduceBulkZeroing = constant i1 true

declare ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32, i1, i1)
declare i32 @jeandle.arraylength(ptr addrspace(1))
declare void @jeandle.copy(ptr addrspace(1), i64, ptr addrspace(1), i64, i64, ptr, ptr, i64, i64)
declare void @safepoint()
declare void @bulk_clone(ptr addrspace(1), i64, ptr addrspace(1), i64, i64)
define void @jeandle.clone_payload(ptr addrspace(1) %src, i64 %src_offset, ptr addrspace(1) %dst, i64 %dst_offset, i64 %count, i1 %instance) #2 {
  call void @bulk_clone(ptr addrspace(1) %src, i64 %src_offset, ptr addrspace(1) %dst, i64 %dst_offset, i64 %count)
  ret void
}

; The payload covers exactly three Java long elements.
define ptr addrspace(1) @three_longs(ptr addrspace(1) "java-klass"="101" %src) #0 {
  %dst = call ptr addrspace(1) @jeandle.new_array(ptr null, i32 3, i32 40, i32 16, i32 1000, i1 false, i1 false)
  call void @jeandle.copy(ptr addrspace(1) %src, i64 16, ptr addrspace(1) %dst, i64 16, i64 3, ptr null, ptr null, i64 40, i64 40) #1
  ret ptr addrspace(1) %dst
}

; COMMON-LABEL: define ptr addrspace(1) @three_longs(
; REDUCE: @jeandle.new_array({{.*}}i1 true, i1 true)
; KEEP: @jeandle.new_array({{.*}}i1 false, i1 false)
; COMMON: getelementptr i8, ptr addrspace(1) %src, i64 16
; COMMON: getelementptr i8, ptr addrspace(1) %dst, i64 16
; COMMON: load atomic volatile i64, {{.*}} unordered
; COMMON: store atomic i64 {{.*}} unordered
; COMMON: load atomic volatile i64, {{.*}} unordered
; COMMON: store atomic i64 {{.*}} unordered
; COMMON: load atomic volatile i64, {{.*}} unordered
; COMMON: store atomic i64 {{.*}} unordered
; COMMON-NOT: load atomic
; COMMON-NOT: @jeandle.clone_payload
; COMMON: call hotspotcc void @jeandle.membar_allocation_init(ptr addrspace(1) %dst)
; COMMON-NEXT: ret ptr addrspace(1) %dst

; Copy only the six payload bytes, leaving the last padding bytes untouched.
define ptr addrspace(1) @three_chars(ptr addrspace(1) "java-klass"="102" %src) #0 {
  %dst = call ptr addrspace(1) @jeandle.new_array(ptr null, i32 3, i32 24, i32 16, i32 1000, i1 false, i1 false)
  call void @jeandle.copy(ptr addrspace(1) %src, i64 16, ptr addrspace(1) %dst, i64 16, i64 1, ptr null, ptr null, i64 22, i64 22) #1
  ret ptr addrspace(1) %dst
}

; COMMON-LABEL: define ptr addrspace(1) @three_chars(
; REDUCE: @jeandle.new_array({{.*}}i1 true, i1 true)
; KEEP: @jeandle.new_array({{.*}}i1 false, i1 false)
; COMMON: load atomic volatile i32, {{.*}} unordered, align 4
; COMMON: store atomic i32 {{.*}} unordered, align 4
; COMMON: load atomic volatile i16, {{.*}} unordered, align 2
; COMMON: store atomic i16 {{.*}} unordered, align 2
; COMMON-NOT: load atomic
; COMMON: call hotspotcc void @jeandle.membar_allocation_init(ptr addrspace(1) %dst)

define ptr addrspace(1) @three_ints(ptr addrspace(1) "java-klass"="103" %src) #0 {
  %dst = call ptr addrspace(1) @jeandle.new_array(ptr null, i32 3, i32 32, i32 16, i32 1000, i1 false, i1 false)
  call void @jeandle.copy(ptr addrspace(1) %src, i64 16, ptr addrspace(1) %dst, i64 16, i64 2, ptr null, ptr null, i64 28, i64 28) #1
  ret ptr addrspace(1) %dst
}

; COMMON-LABEL: define ptr addrspace(1) @three_ints(
; REDUCE: @jeandle.new_array({{.*}}i1 true, i1 true)
; KEEP: @jeandle.new_array({{.*}}i1 false, i1 false)
; COMMON: getelementptr i8, ptr addrspace(1) %src, i64 16
; COMMON: getelementptr i8, ptr addrspace(1) %dst, i64 16
; COMMON: load atomic volatile i64, {{.*}} unordered, align 8
; COMMON: store atomic i64 {{.*}} unordered, align 8
; COMMON: load atomic volatile i32, {{.*}} unordered, align 4
; COMMON: store atomic i32 {{.*}} unordered, align 4
; COMMON-NOT: load atomic
; COMMON: call hotspotcc void @jeandle.membar_allocation_init(ptr addrspace(1) %dst)

define ptr addrspace(1) @one_byte(ptr addrspace(1) "java-klass"="104" %src) #0 {
  %dst = call ptr addrspace(1) @jeandle.new_array(ptr null, i32 1, i32 24, i32 16, i32 1000, i1 false, i1 false)
  call void @jeandle.copy(ptr addrspace(1) %src, i64 16, ptr addrspace(1) %dst, i64 16, i64 1, ptr null, ptr null, i64 17, i64 17) #1
  ret ptr addrspace(1) %dst
}

; COMMON-LABEL: define ptr addrspace(1) @one_byte(
; REDUCE: @jeandle.new_array({{.*}}i1 true, i1 true)
; KEEP: @jeandle.new_array({{.*}}i1 false, i1 false)
; COMMON: getelementptr i8, ptr addrspace(1) %src, i64 16
; COMMON: getelementptr i8, ptr addrspace(1) %dst, i64 16
; COMMON: load atomic volatile i8, {{.*}} unordered
; COMMON: store atomic i8 {{.*}} unordered
; COMMON-NOT: load atomic
; COMMON: call hotspotcc void @jeandle.membar_allocation_init(ptr addrspace(1) %dst)

; With PEA disabled, the source arraylength may still be a JavaOp when the
; clone is specialized. Its source allocation also establishes the count.
define ptr addrspace(1) @local_source_length() #0 {
  %src = call "java-klass"="103" ptr addrspace(1) @jeandle.new_array(ptr null, i32 3, i32 32, i32 16, i32 1000, i1 false, i1 false)
  %length = call i32 @jeandle.arraylength(ptr addrspace(1) %src)
  %dst = call ptr addrspace(1) @jeandle.new_array(ptr null, i32 %length, i32 32, i32 16, i32 1000, i1 false, i1 false)
  call void @jeandle.copy(ptr addrspace(1) %src, i64 16, ptr addrspace(1) %dst, i64 16, i64 2, ptr null, ptr null, i64 28, i64 28) #1
  ret ptr addrspace(1) %dst
}

; COMMON-LABEL: define ptr addrspace(1) @local_source_length(
; COMMON: %src = call {{.*}}@jeandle.new_array({{.*}}i1 false, i1 false)
; COMMON: %length = call i32 @jeandle.arraylength(ptr addrspace(1) %src)
; REDUCE: %dst = call {{.*}}@jeandle.new_array({{.*}}i1 true, i1 true)
; KEEP: %dst = call {{.*}}@jeandle.new_array({{.*}}i1 false, i1 false)
; COMMON: load atomic volatile i64, {{.*}} unordered, align 8
; COMMON: store atomic i64 {{.*}} unordered, align 8
; COMMON: load atomic volatile i32, {{.*}} unordered, align 4
; COMMON: store atomic i32 {{.*}} unordered, align 4
; COMMON-NOT: load atomic
; COMMON: call hotspotcc void @jeandle.membar_allocation_init(ptr addrspace(1) %dst)

define ptr addrspace(1) @local_source_dynamic_count() #0 {
  %src = call "java-klass"="103" ptr addrspace(1) @jeandle.new_array(ptr null, i32 3, i32 32, i32 16, i32 1000, i1 false, i1 false)
  %length = call i32 @jeandle.arraylength(ptr addrspace(1) %src)
  %dst = call ptr addrspace(1) @jeandle.new_array(ptr null, i32 %length, i32 32, i32 16, i32 1000, i1 false, i1 false)
  %length64 = sext i32 %length to i64
  %bytes = shl i64 %length64, 2
  %rounded = add i64 %bytes, 7
  %words = lshr i64 %rounded, 3
  call void @jeandle.copy(ptr addrspace(1) %src, i64 16, ptr addrspace(1) %dst, i64 16, i64 %words, ptr null, ptr null, i64 28, i64 28) #1
  ret ptr addrspace(1) %dst
}

; COMMON-LABEL: define ptr addrspace(1) @local_source_dynamic_count(
; COMMON: %src = call {{.*}}@jeandle.new_array({{.*}}i1 false, i1 false)
; COMMON: %length = call i32 @jeandle.arraylength(ptr addrspace(1) %src)
; REDUCE: %dst = call {{.*}}@jeandle.new_array({{.*}}i1 true, i1 true)
; KEEP: %dst = call {{.*}}@jeandle.new_array({{.*}}i1 false, i1 false)
; COMMON: load atomic volatile i64, {{.*}} unordered, align 8
; COMMON: store atomic i64 {{.*}} unordered, align 8
; COMMON: load atomic volatile i32, {{.*}} unordered, align 4
; COMMON: store atomic i32 {{.*}} unordered, align 4
; COMMON-NOT: load atomic
; COMMON: call hotspotcc void @jeandle.membar_allocation_init(ptr addrspace(1) %dst)

define ptr addrspace(1) @intervening_gc(ptr addrspace(1) "java-klass"="101" %src) #0 {
  %dst = call ptr addrspace(1) @jeandle.new_array(ptr null, i32 3, i32 40, i32 16, i32 1000, i1 false, i1 false)
  call void @safepoint()
  call void @jeandle.copy(ptr addrspace(1) %src, i64 16, ptr addrspace(1) %dst, i64 16, i64 3, ptr null, ptr null, i64 40, i64 40) #1
  ret ptr addrspace(1) %dst
}

; COMMON-LABEL: define ptr addrspace(1) @intervening_gc(
; COMMON: @jeandle.new_array({{.*}}i1 false, i1 false)
; COMMON-NEXT: call void @safepoint()
; COMMON: load atomic volatile i64
; COMMON: call hotspotcc void @jeandle.membar_allocation_init(ptr addrspace(1) %dst)

define ptr addrspace(1) @dynamic_length(ptr addrspace(1) "java-klass"="101" %src, i32 %length, i64 %payload_count) #0 {
  %dst = call ptr addrspace(1) @jeandle.new_array(ptr null, i32 %length, i32 40, i32 16, i32 1000, i1 false, i1 false)
  call void @jeandle.copy(ptr addrspace(1) %src, i64 8, ptr addrspace(1) %dst, i64 8, i64 %payload_count, ptr null, ptr null, i64 40, i64 40) #1
  ret ptr addrspace(1) %dst
}

; COMMON-LABEL: define ptr addrspace(1) @dynamic_length(
; COMMON: @jeandle.new_array({{.*}}i1 false, i1 false)
; COMMON-NOT: load atomic
; COMMON: call hotspotcc void @jeandle.clone_payload({{.*}}i64 %payload_count, i1 false)
; COMMON: call hotspotcc void @jeandle.membar_allocation_init(ptr addrspace(1) %dst)

define ptr addrspace(1) @above_threshold(ptr addrspace(1) "java-klass"="101" %src) #0 {
  %dst = call ptr addrspace(1) @jeandle.new_array(ptr null, i32 9, i32 88, i32 16, i32 1000, i1 false, i1 false)
  call void @jeandle.copy(ptr addrspace(1) %src, i64 8, ptr addrspace(1) %dst, i64 8, i64 10, ptr null, ptr null, i64 88, i64 88) #1
  ret ptr addrspace(1) %dst
}

; COMMON-LABEL: define ptr addrspace(1) @above_threshold(
; COMMON: @jeandle.new_array({{.*}}i1 false, i1 false)
; COMMON-NOT: load atomic
; COMMON: call hotspotcc void @jeandle.clone_payload({{.*}}i64 10, i1 false)

; A logical full clone requires the original raw range to cover its payload.
define ptr addrspace(1) @partial_payload(ptr addrspace(1) "java-klass"="103" %src, i64 %words) #0 {
  %dst = call ptr addrspace(1) @jeandle.new_array(ptr null, i32 3, i32 32, i32 16, i32 1000, i1 false, i1 false)
  call void @jeandle.copy(ptr addrspace(1) %src, i64 16, ptr addrspace(1) %dst, i64 16, i64 1, ptr null, ptr null, i64 28, i64 28) #1
  ret ptr addrspace(1) %dst
}

; COMMON-LABEL: define ptr addrspace(1) @partial_payload(
; COMMON: @jeandle.new_array({{.*}}i1 false, i1 false)
; COMMON-NOT: load atomic
; COMMON: call hotspotcc void @jeandle.clone_payload({{.*}}i64 1, i1 false)
; COMMON: call hotspotcc void @jeandle.membar_allocation_init(ptr addrspace(1) %dst)

; A logical full clone requires the original raw range to cover its payload.
define ptr addrspace(1) @excess_payload(ptr addrspace(1) "java-klass"="103" %src, i64 %words) #0 {
  %dst = call ptr addrspace(1) @jeandle.new_array(ptr null, i32 3, i32 32, i32 16, i32 1000, i1 false, i1 false)
  call void @jeandle.copy(ptr addrspace(1) %src, i64 16, ptr addrspace(1) %dst, i64 16, i64 3, ptr null, ptr null, i64 28, i64 28) #1
  ret ptr addrspace(1) %dst
}

; COMMON-LABEL: define ptr addrspace(1) @excess_payload(
; COMMON: @jeandle.new_array({{.*}}i1 false, i1 false)
; COMMON-NOT: load atomic
; COMMON: call hotspotcc void @jeandle.clone_payload({{.*}}i64 3, i1 false)
; COMMON: call hotspotcc void @jeandle.membar_allocation_init(ptr addrspace(1) %dst)

; A logical full clone requires the original raw range to cover its payload.
define ptr addrspace(1) @unequal_offsets(ptr addrspace(1) "java-klass"="103" %src, i64 %words) #0 {
  %dst = call ptr addrspace(1) @jeandle.new_array(ptr null, i32 3, i32 32, i32 16, i32 1000, i1 false, i1 false)
  call void @jeandle.copy(ptr addrspace(1) %src, i64 8, ptr addrspace(1) %dst, i64 16, i64 2, ptr null, ptr null, i64 28, i64 28) #1
  ret ptr addrspace(1) %dst
}

; COMMON-LABEL: define ptr addrspace(1) @unequal_offsets(
; COMMON: @jeandle.new_array({{.*}}i1 false, i1 false)
; COMMON-NOT: load atomic
; COMMON: call hotspotcc void @jeandle.clone_payload({{.*}}i64 2, i1 false)
; COMMON: call hotspotcc void @jeandle.membar_allocation_init(ptr addrspace(1) %dst)

; A logical full clone requires the original raw range to cover its payload.
define ptr addrspace(1) @shifted_payload(ptr addrspace(1) "java-klass"="103" %src, i64 %words) #0 {
  %dst = call ptr addrspace(1) @jeandle.new_array(ptr null, i32 3, i32 32, i32 16, i32 1000, i1 false, i1 false)
  call void @jeandle.copy(ptr addrspace(1) %src, i64 24, ptr addrspace(1) %dst, i64 24, i64 2, ptr null, ptr null, i64 28, i64 28) #1
  ret ptr addrspace(1) %dst
}

; COMMON-LABEL: define ptr addrspace(1) @shifted_payload(
; COMMON: @jeandle.new_array({{.*}}i1 false, i1 false)
; COMMON-NOT: load atomic
; COMMON: call hotspotcc void @jeandle.clone_payload({{.*}}i64 2, i1 false)
; COMMON: call hotspotcc void @jeandle.membar_allocation_init(ptr addrspace(1) %dst)

; A logical full clone requires the original raw range to cover its payload.
define ptr addrspace(1) @unknown_payload(ptr addrspace(1) "java-klass"="103" %src, i64 %words) #0 {
  %dst = call ptr addrspace(1) @jeandle.new_array(ptr null, i32 3, i32 32, i32 16, i32 1000, i1 false, i1 false)
  call void @jeandle.copy(ptr addrspace(1) %src, i64 16, ptr addrspace(1) %dst, i64 16, i64 %words, ptr null, ptr null, i64 28, i64 28) #1
  ret ptr addrspace(1) %dst
}

; COMMON-LABEL: define ptr addrspace(1) @unknown_payload(
; COMMON: @jeandle.new_array({{.*}}i1 false, i1 false)
; COMMON-NOT: load atomic
; COMMON: call hotspotcc void @jeandle.clone_payload({{.*}}i64 %words, i1 false)
; COMMON: call hotspotcc void @jeandle.membar_allocation_init(ptr addrspace(1) %dst)

 ; A raw range that can overwrite the klass cannot become element stores.
define ptr addrspace(1) @klass_in_payload(ptr addrspace(1) "java-klass"="103" %src) #0 {
  %dst = call ptr addrspace(1) @jeandle.new_array(ptr null, i32 3, i32 32, i32 16, i32 1000, i1 false, i1 false)
  call void @jeandle.copy(ptr addrspace(1) %src, i64 8, ptr addrspace(1) %dst, i64 8, i64 3, ptr null, ptr null, i64 28, i64 28) #1
  ret ptr addrspace(1) %dst
}
; COMMON-LABEL: define ptr addrspace(1) @klass_in_payload(
; COMMON: @jeandle.new_array({{.*}}i1 false, i1 false)
; COMMON-NOT: load atomic
; COMMON: call hotspotcc void @jeandle.clone_payload({{.*}}i64 3, i1 false)

define ptr addrspace(1) @eight_bytes(ptr addrspace(1) "java-klass"="104" %src) #0 {
  %dst = call ptr addrspace(1) @jeandle.new_array(ptr null, i32 8, i32 24, i32 16, i32 1000, i1 false, i1 false)
  call void @jeandle.copy(ptr addrspace(1) %src, i64 16, ptr addrspace(1) %dst, i64 16, i64 1, ptr null, ptr null, i64 24, i64 24) #1
  ret ptr addrspace(1) %dst
}
; COMMON-LABEL: define ptr addrspace(1) @eight_bytes(
; COMMON: load atomic volatile i64, {{.*}} unordered, align 8
; COMMON: store atomic i64 {{.*}} unordered, align 8
; COMMON-NOT: load atomic
; COMMON-NOT: @jeandle.clone_payload
; COMMON: call hotspotcc void @jeandle.membar_allocation_init


attributes #0 = { "java-method"="0" }
attributes #1 = { "jeandle.copy.kind"="clone-array" "jeandle.copy.tightly-coupled-allocation" }
attributes #2 = { nounwind "gc-leaf-function" "lower-phase"="1" }
!java-method-compilation = !{}
