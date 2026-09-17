; RUN: opt -S -passes="function(arraycopy-specialization),java-operation-lower<phase=1>" -jeandle-vm-callback-log=%S/Inputs/clone-instance.cblog %s 2>&1 | FileCheck %s
; RUN: opt -S -passes="function(arraycopy-specialization),java-operation-lower<phase=1>" -jeandle-vm-callback-log=%S/Inputs/clone-instance.cblog %s 2>&1 | llc -mtriple=aarch64-linux-gnu -O2 -o - | FileCheck %s --check-prefix=AARCH64

target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-p3:32:32:32-i8:8:32-i16:16:32-i64:64-i128:128-n32:64-S128-Fn32"
target triple = "aarch64-unknown-linux-gnu"

@jeandle.personality = global ptr null
@ArrayCopyLoadStoreMaxElem = constant i32 0
@arrayOopDesc.base_offset_in_bytes.object = constant i32 16
@heapOopSize = constant i32 4
@WordSize = constant i32 8
@ArrayOperationPartialInlineSize = constant i32 0

declare hotspotcc void @jeandle.arraycopy(
    ptr addrspace(1), i64, ptr addrspace(1), i64, i64,
    ptr, ptr, i64, i64)
declare void @StubRoutines_jlong_disjoint_arraycopy(
    ptr addrspace(1), ptr addrspace(1), i64)
declare void @StubRoutines_arrayof_oop_disjoint_arraycopy(
    ptr addrspace(1), ptr addrspace(1), i64)
declare hotspotcc void @SharedRuntime_slow_arraycopy_C(
    ptr addrspace(1), i32, ptr addrspace(1), i32, i32, ptr)

; Serial and G1 with ReduceInitialCardMarks use the generic raw clone path.
define hotspotcc void @jeandle.clone_at_expansion(
    ptr addrspace(1) %src, i64 %src_offset,
    ptr addrspace(1) %dest, i64 %dest_offset, i64 %length,
    i1 %is_clone_inst) #3 {
entry:
  %payload_src = getelementptr i8, ptr addrspace(1) %src, i64 %src_offset
  %payload_dest = getelementptr i8, ptr addrspace(1) %dest, i64 %dest_offset
  call void @StubRoutines_jlong_disjoint_arraycopy(
      ptr addrspace(1) %payload_src, ptr addrspace(1) %payload_dest,
      i64 %length)
  ret void
}

define hotspotcc void @clone_basic_expansion(
    ptr addrspace(1) %src, ptr addrspace(1) %dest) #0
    gc "hotspotgc" personality ptr @jeandle.personality {
entry:
  invoke hotspotcc void @jeandle.arraycopy(
      ptr addrspace(1) %src, i64 8,
      ptr addrspace(1) %dest, i64 8, i64 5,
      ptr null, ptr null, i64 48, i64 48) #1
      [ "deopt"(i32 0) ]
      to label %normal unwind label %exception

normal:
  ret void

exception:
  %landingpad = landingpad { ptr, i32 } cleanup
  ret void
}

; CHECK-LABEL: define hotspotcc void @clone_basic_expansion(
; CHECK: [[SRC:%.*]] = getelementptr i8, ptr addrspace(1) %src, i64 8
; CHECK: [[DEST:%.*]] = getelementptr i8, ptr addrspace(1) %dest, i64 8
; CHECK: call void @StubRoutines_jlong_disjoint_arraycopy(ptr addrspace(1) [[SRC]], ptr addrspace(1) [[DEST]], i64 5)
; CHECK-NOT: @jeandle.arraycopy
; CHECK: br label %normal

; AARCH64-LABEL: clone_basic_expansion:
; AARCH64: add x0, x1, #8
; AARCH64: add x1, x2, #8
; AARCH64: bl StubRoutines_jlong_disjoint_arraycopy

define hotspotcc void @clone_oop_array_expansion(
    ptr addrspace(1) %src, ptr addrspace(1) %dest, i64 %length,
    ptr %klass) #0 gc "hotspotgc" personality ptr @jeandle.personality {
entry:
  invoke hotspotcc void @jeandle.arraycopy(
      ptr addrspace(1) %src, i64 0,
      ptr addrspace(1) %dest, i64 0, i64 %length,
      ptr %klass, ptr %klass, i64 %length, i64 %length) #2
      [ "deopt"(i32 0) ]
      to label %normal unwind label %exception

normal:
  ret void

exception:
  %landingpad = landingpad { ptr, i32 } cleanup
  ret void
}

; CHECK-LABEL: define hotspotcc void @clone_oop_array_expansion(
; CHECK: [[NONPOS:%.*]] = icmp sle i64 %length, 0
; CHECK: br i1 [[NONPOS]], label %arraycopy.nonpositive, label %arraycopy.nonpositive.fast
; CHECK: arraycopy.slow_call:
; CHECK: invoke hotspotcc void @SharedRuntime_slow_arraycopy_C
; CHECK: arraycopy.result:
; CHECK-NEXT: fence seq_cst
; CHECK: arraycopy.nonpositive:
; CHECK: [[NEGATIVE:%.*]] = icmp slt i64 %length, 0
; CHECK: br i1 [[NEGATIVE]], label %arraycopy.slow_region, label %arraycopy.length.fast
; CHECK: arraycopy.nonpositive.fast:
; CHECK: [[SRC_BASE:%.*]] = getelementptr i8, ptr addrspace(1) %src, i64 16
; CHECK: [[SRC_ADDRESS:%.*]] = getelementptr i8, ptr addrspace(1) [[SRC_BASE]], i64 0
; CHECK: [[DEST_BASE:%.*]] = getelementptr i8, ptr addrspace(1) %dest, i64 16
; CHECK: [[DEST_ADDRESS:%.*]] = getelementptr i8, ptr addrspace(1) [[DEST_BASE]], i64 0
; CHECK: call void @StubRoutines_arrayof_oop_disjoint_arraycopy(ptr addrspace(1) [[SRC_ADDRESS]], ptr addrspace(1) [[DEST_ADDRESS]], i64 %length)
; CHECK-NOT: @jeandle.arraycopy

; AARCH64-LABEL: clone_oop_array_expansion:
; AARCH64: cmp {{[wx]}}{{[0-9]+}}, #1
; AARCH64: b.lt
; AARCH64: add x0, x1, #16
; AARCH64: add x1, x{{[0-9]+}}, #16
; AARCH64: bl StubRoutines_arrayof_oop_disjoint_arraycopy
; AARCH64: dmb ish
; AARCH64: bl SharedRuntime_slow_arraycopy_C

define hotspotcc void @clone_oop_array_zero(
    ptr addrspace(1) %src, ptr addrspace(1) %dest, ptr %klass) #0
    gc "hotspotgc" personality ptr @jeandle.personality {
entry:
  invoke hotspotcc void @jeandle.arraycopy(
      ptr addrspace(1) %src, i64 0,
      ptr addrspace(1) %dest, i64 0, i64 0,
      ptr %klass, ptr %klass, i64 0, i64 0) #2
      [ "deopt"(i32 0) ]
      to label %normal unwind label %exception

normal:
  ret void

exception:
  %landingpad = landingpad { ptr, i32 } cleanup
  ret void
}

; CHECK-LABEL: define hotspotcc void @clone_oop_array_zero(
; CHECK-NOT: @jeandle.arraycopy
; CHECK: br i1 true, label %arraycopy.nonpositive, label %arraycopy.nonpositive.fast
; CHECK: arraycopy.result:
; CHECK-NEXT: fence seq_cst
; CHECK: arraycopy.nonpositive:
; CHECK-NEXT: br label %arraycopy.result

; AARCH64-LABEL: clone_oop_array_zero:
; AARCH64-NOT: StubRoutines_arrayof_oop_disjoint_arraycopy
; AARCH64: ret

attributes #0 = { "java-method"="0" }
attributes #1 = { "jeandle.arraycopy.kind"="clone-array" }
attributes #2 = { "jeandle.arraycopy.kind"="clone-oop-array" }
attributes #3 = { noinline nounwind "gc-leaf-function" "lower-phase"="1" }

!current-thread = !{!0}
!java-method-compilation = !{}

!0 = !{!"x28"}
