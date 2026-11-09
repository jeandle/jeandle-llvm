; RUN: opt -S -verify-each -passes='copy-specialization' -jeandle-vm-callback-log=%S/Inputs/integer-width.cblog %s | FileCheck %s
; RUN: opt -S -verify-each -passes='copy-specialization' -mattr=+avx512bw,+avx512vl -jeandle-vm-callback-log=%S/Inputs/integer-width.cblog %s | FileCheck %s --check-prefix=PARTIAL
; REQUIRES: x86-registered-target

; Legacy i32 pseudo operands must be widened before byte scaling, bounds
; arithmetic, and the masked-copy/stub split. Real stub ABIs remain unchanged.
target triple = "x86_64-unknown-linux-gnu"
target datalayout = "e-p:64:64"

@ArrayCopyLoadStoreMaxElem = constant i32 8
@VMOptions.ArrayOperationPartialInlineSize = constant i32 32
@WordSize = constant i64 8
@personality = global ptr null

declare void @jeandle.copy(ptr addrspace(1), i32, ptr addrspace(1), i32, i32, ptr, ptr, i32, i32)
declare void @StubRoutines_arrayof_jlong_disjoint_arraycopy(ptr addrspace(1), ptr addrspace(1), i64)
declare void @StubRoutines_jshort_disjoint_arraycopy(ptr addrspace(1), ptr addrspace(1), i64)
declare hotspotcc void @SharedRuntime_slow_arraycopy_C(ptr addrspace(1), i32, ptr addrspace(1), i32, i32, ptr)

define hotspotcc void @jeandle.clone_payload(ptr addrspace(1) %src, i64 %src_offset, ptr addrspace(1) %dest, i64 %dest_offset, i64 %length, i1 %is_instance) {
  %from = getelementptr i8, ptr addrspace(1) %src, i64 %src_offset
  %to = getelementptr i8, ptr addrspace(1) %dest, i64 %dest_offset
  call void @StubRoutines_arrayof_jlong_disjoint_arraycopy(ptr addrspace(1) %from, ptr addrspace(1) %to, i64 %length)
  ret void
}

define void @large_long_index(ptr addrspace(1) "java-klass"="101" %src, ptr addrspace(1) "java-klass"="101" %dest) #0 personality ptr @personality {
entry:
  invoke void @jeandle.copy(ptr addrspace(1) %src, i32 536870912, ptr addrspace(1) %dest, i32 536870912, i32 1, ptr null, ptr null, i32 536870913, i32 536870913) #1 [ "deopt"(i32 0) ] to label %normal unwind label %exception
normal:
  ret void
exception:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @large_long_index(
; CHECK: [[SRCBASE:%.*]] = getelementptr i8, ptr addrspace(1) %src, i64 16
; CHECK: [[SRC:%.*]] = getelementptr i8, ptr addrspace(1) [[SRCBASE]], i64 4294967296
; CHECK: [[DESTBASE:%.*]] = getelementptr i8, ptr addrspace(1) %dest, i64 16
; CHECK: [[DEST:%.*]] = getelementptr i8, ptr addrspace(1) [[DESTBASE]], i64 4294967296
; CHECK: [[VALUE:%.*]] = load atomic volatile i64, ptr addrspace(1) [[SRC]] unordered
; CHECK: store atomic i64 [[VALUE]], ptr addrspace(1) [[DEST]] unordered
; CHECK-NOT: @jeandle.copy
; CHECK: ret void

define void @dynamic_char_copy(ptr addrspace(1) "java-klass"="102" %src, ptr addrspace(1) "java-klass"="102" %dest, i32 %offset, i32 %length, i32 %array_length) #0 personality ptr @personality {
entry:
  invoke void @jeandle.copy(ptr addrspace(1) %src, i32 %offset, ptr addrspace(1) %dest, i32 %offset, i32 %length, ptr null, ptr null, i32 %array_length, i32 %array_length) #2 [ "deopt"(i32 0) ] to label %normal unwind label %exception
normal:
  ret void
exception:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @dynamic_char_copy(
; CHECK: [[OFFSET:%.*]] = sext i32 %offset to i64
; CHECK: [[LENGTH:%.*]] = sext i32 %length to i64
; CHECK: [[LAST:%.*]] = add i64 [[LENGTH]], [[OFFSET]]
; CHECK: icmp ult i64 {{%.*}}, [[LAST]]
; CHECK: [[SCALE:%.*]] = shl i64 [[OFFSET]], 1
; CHECK: getelementptr i8, ptr addrspace(1) {{%.*}}, i64 [[SCALE]]
; CHECK: call void @StubRoutines_jshort_disjoint_arraycopy({{.*}}i64 [[LENGTH]])
; CHECK-NOT: @jeandle.copy

; PARTIAL-LABEL: define void @dynamic_char_copy(
; PARTIAL: [[LENGTH:%.*]] = sext i32 %length to i64
; PARTIAL: [[BYTES:%.*]] = shl i64 [[LENGTH]], 1
; PARTIAL: icmp ule i64 [[BYTES]], 32
; PARTIAL-NEXT: br i1 {{%.*}}, label %arraycopy.partial.inline, label %arraycopy.partial.stub, !prof [[INLINE_WEIGHTS:![0-9]+]]
; PARTIAL: call <16 x i16> @llvm.masked.load
; PARTIAL: call void @llvm.masked.store
; PARTIAL: call void @StubRoutines_jshort_disjoint_arraycopy

; A primitive clone's count is payload longs, so it must stay on the bulk
; JavaOp path even when its source element type and payload count are known.
define void @legacy_primitive_clone(ptr addrspace(1) "java-klass"="101" %src, ptr addrspace(1) %dest) #0 {
  call void @jeandle.copy(ptr addrspace(1) %src, i32 8, ptr addrspace(1) %dest, i32 8, i32 2, ptr null, ptr null, i32 24, i32 24) #3
  ret void
}

; CHECK-LABEL: define void @legacy_primitive_clone(
; CHECK-NOT: load atomic
; CHECK: call hotspotcc void @jeandle.clone_payload(ptr addrspace(1) %src, i64 8, ptr addrspace(1) %dest, i64 8, i64 2, i1 false)
; CHECK-NEXT: call hotspotcc void @jeandle.membar_allocation_init(ptr addrspace(1) %dest)
; CHECK-NEXT: ret void

attributes #0 = { "java-method"="0" }
attributes #1 = { "jeandle.copy.kind"="arraycopy" "jeandle.copy.validated" }
attributes #2 = { "jeandle.copy.kind"="arraycopy" }
attributes #3 = { "jeandle.copy.kind"="clone-array" }

!java-method-compilation = !{}
!current-thread = !{!0}
!0 = !{!"r15"}

; PARTIAL: [[INLINE_WEIGHTS]] = !{!"branch_weights", i32 999999, i32 1}
