; RUN: opt -S -verify-each -passes='copy-specialization' -jeandle-vm-callback-log=%S/Inputs/uninitialized-destination.cblog %s | FileCheck %s --check-prefixes=COMMON,UNINIT
; RUN: sed 's/@VMOptions.ReduceBulkZeroing = constant i1 true/@VMOptions.ReduceBulkZeroing = constant i1 false/' %s | opt -S -verify-each -passes='copy-specialization' -jeandle-vm-callback-log=%S/Inputs/uninitialized-destination.cblog | FileCheck %s --check-prefixes=COMMON,INIT
; RUN: sed '/^@Klass.super_check_offset_offset =/d' %s | opt -S -verify-each -passes=copy-specialization -jeandle-vm-callback-log=%S/Inputs/uninitialized-destination.cblog | FileCheck %s --check-prefix=MISSING-OFFSET

; Without the VM layout global, retain the slow invoke and its exception state.
; MISSING-OFFSET-LABEL: define ptr addrspace(1) @checkcast_fresh(
; MISSING-OFFSET-NOT: call i32 @StubRoutines_checkcast_arraycopy
; MISSING-OFFSET: invoke hotspotcc void @SharedRuntime_slow_arraycopy_C
; MISSING-OFFSET: fence release
; MISSING-OFFSET-LABEL: define void @checkcast_existing(
; MISSING-OFFSET-NOT: call i32 @StubRoutines_checkcast_arraycopy
; MISSING-OFFSET: invoke hotspotcc void @SharedRuntime_slow_arraycopy_C

@VMOptions.ReduceBulkZeroing = constant i1 true
@VMOptions.ArrayCopyLoadStoreMaxElem = constant i32 0
@WordSize = constant i64 8
@heapOopSize = constant i32 4
@Klass.super_check_offset_offset = constant i32 20
@personality = global ptr null

declare "java-klass"="202" ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32, i1, i1)
declare void @jeandle.copy(ptr addrspace(1), i64, ptr addrspace(1), i64, i64, ptr, ptr, i64, i64)
declare hotspotcc i1 @jeandle.check_klass_subtype(ptr, ptr)
declare hotspotcc ptr @jeandle.load_array_element_klass(ptr)
declare void @StubRoutines_arrayof_oop_disjoint_arraycopy(ptr addrspace(1), ptr addrspace(1), i64)
declare void @StubRoutines_arrayof_oop_disjoint_arraycopy_uninit(ptr addrspace(1), ptr addrspace(1), i64)
declare void @StubRoutines_oop_disjoint_arraycopy(ptr addrspace(1), ptr addrspace(1), i64)
declare void @StubRoutines_oop_disjoint_arraycopy_uninit(ptr addrspace(1), ptr addrspace(1), i64)
declare i32 @StubRoutines_checkcast_arraycopy(ptr addrspace(1), ptr addrspace(1), i64, i64, ptr)
declare i32 @StubRoutines_checkcast_arraycopy_uninit(ptr addrspace(1), ptr addrspace(1), i64, i64, ptr)
declare hotspotcc void @SharedRuntime_slow_arraycopy_C(ptr addrspace(1), i32, ptr addrspace(1), i32, i32, ptr)

define ptr addrspace(1) @copyof(ptr addrspace(1) "java-klass"="201" %src) #0 personality ptr @personality {
entry:
  %dest = call ptr addrspace(1) @jeandle.new_array(ptr null, i32 8, i32 48, i32 16, i32 1000, i1 false, i1 false)
  invoke void @jeandle.copy(ptr addrspace(1) %src, i64 0, ptr addrspace(1) %dest, i64 0, i64 8, ptr null, ptr null, i64 8, i64 8) #1 [ "deopt"(i32 0) ] to label %normal unwind label %exception
normal:
  ret ptr addrspace(1) %dest
exception:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; COMMON-LABEL: define ptr addrspace(1) @copyof(
; COMMON-NOT: @jeandle.check_klass_subtype
; UNINIT: call void @StubRoutines_arrayof_oop_disjoint_arraycopy_uninit({{.*}}i64 8)
; INIT: call void @StubRoutines_arrayof_oop_disjoint_arraycopy({{.*}}i64 8)
; COMMON: arraycopy.result:
; COMMON-NEXT: fence release
; COMMON-NEXT: br label %normal
; COMMON-NOT: @jeandle.copy

define ptr addrspace(1) @copyof_range(ptr addrspace(1) "java-klass"="201" %src) #0 personality ptr @personality {
entry:
  %dest = call ptr addrspace(1) @jeandle.new_array(ptr null, i32 8, i32 48, i32 16, i32 1000, i1 false, i1 false)
  invoke void @jeandle.copy(ptr addrspace(1) %src, i64 1, ptr addrspace(1) %dest, i64 0, i64 7, ptr null, ptr null, i64 8, i64 8) #2 [ "deopt"(i32 0) ] to label %normal unwind label %exception
normal:
  ret ptr addrspace(1) %dest
exception:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; COMMON-LABEL: define ptr addrspace(1) @copyof_range(
; COMMON-NOT: @jeandle.check_klass_subtype
; UNINIT: call void @StubRoutines_oop_disjoint_arraycopy_uninit({{.*}}i64 7)
; INIT: call void @StubRoutines_oop_disjoint_arraycopy({{.*}}i64 7)
; COMMON: arraycopy.result:
; COMMON-NEXT: fence release
; COMMON-NEXT: br label %normal
; COMMON-NOT: @jeandle.copy

; Ordinary tightly coupled arraycopy is accepted by the allocation finder,
; including the checkcast path and its partial-copy slow continuation.
define ptr addrspace(1) @checkcast_fresh(ptr addrspace(1) "java-klass"="201" %src, ptr %src_klass, ptr %dest_klass) #0 personality ptr @personality {
entry:
  %dest = call "java-klass"="202" ptr addrspace(1) @jeandle.new_array(ptr null, i32 8, i32 48, i32 16, i32 1000, i1 false, i1 false)
  invoke void @jeandle.copy(ptr addrspace(1) %src, i64 0, ptr addrspace(1) %dest, i64 0, i64 8, ptr %src_klass, ptr %dest_klass, i64 8, i64 8) #3 [ "deopt"(i32 0) ] to label %normal unwind label %exception
normal:
  ret ptr addrspace(1) %dest
exception:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; COMMON-LABEL: define ptr addrspace(1) @checkcast_fresh(
; UNINIT: [[RESULT:%.*]] = call i32 @StubRoutines_checkcast_arraycopy_uninit({{.*}}i64 8,
; INIT: [[RESULT:%.*]] = call i32 @StubRoutines_checkcast_arraycopy({{.*}}i64 8,
; COMMON: [[OFFSET:%.*]] = phi i64 [ 0, %arraycopy.slow_region ], [ [[COPIED:%.*]], %arraycopy.checkcast.failure ]
; COMMON: [[SRC:%.*]] = add i64 0, [[OFFSET]]
; COMMON: [[DEST:%.*]] = add i64 0, [[OFFSET]]
; COMMON: [[LENGTH:%.*]] = sub i64 8, [[OFFSET]]
; COMMON: [[SRC32:%.*]] = trunc i64 [[SRC]] to i32
; COMMON: [[DEST32:%.*]] = trunc i64 [[DEST]] to i32
; COMMON: [[LENGTH32:%.*]] = trunc i64 [[LENGTH]] to i32
; COMMON: invoke hotspotcc void @SharedRuntime_slow_arraycopy_C(ptr addrspace(1) %src, i32 [[SRC32]], ptr addrspace(1) %dest, i32 [[DEST32]], i32 [[LENGTH32]],
; COMMON: [[RAW:%.*]] = xor i32 [[RESULT]], -1
; COMMON: [[COPIED]] = sext i32 [[RAW]] to i64
; COMMON-NOT: @jeandle.copy

; Without the tightly-coupled proof, existing destinations always retain the
; initialized stubs, even when ReduceBulkZeroing is enabled.
define void @checkcast_existing(ptr addrspace(1) "java-klass"="201" %src, ptr addrspace(1) "java-klass"="202" %dest, ptr %src_klass, ptr %dest_klass) #0 personality ptr @personality {
entry:
  invoke void @jeandle.copy(ptr addrspace(1) %src, i64 0, ptr addrspace(1) %dest, i64 0, i64 8, ptr %src_klass, ptr %dest_klass, i64 8, i64 8) #4 [ "deopt"(i32 0) ] to label %normal unwind label %exception
normal:
  ret void
exception:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; COMMON-LABEL: define void @checkcast_existing(
; COMMON: call i32 @StubRoutines_checkcast_arraycopy(
; COMMON: call void @StubRoutines_arrayof_oop_disjoint_arraycopy(
; COMMON-NOT: fence
; COMMON-NOT: @jeandle.copy

; Without validated-copy, copyOf[Range] must retain store checks and continue
; from the copied prefix when a checkcast stub fails.
define ptr addrspace(1) @copyof_checkcast(ptr addrspace(1) %src, ptr %src_klass, ptr %dest_klass) #0 personality ptr @personality {
entry:
  %dest = call ptr addrspace(1) @jeandle.new_array(ptr null, i32 8, i32 48, i32 16, i32 1000, i1 false, i1 false)
  invoke void @jeandle.copy(ptr addrspace(1) %src, i64 0, ptr addrspace(1) %dest, i64 0, i64 8, ptr %src_klass, ptr %dest_klass, i64 8, i64 8) #5 [ "deopt"(i32 1) ] to label %normal unwind label %exception
normal:
  ret ptr addrspace(1) %dest
exception:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; COMMON-LABEL: define ptr addrspace(1) @copyof_checkcast(
; UNINIT: call i32 @StubRoutines_checkcast_arraycopy_uninit(
; INIT: call i32 @StubRoutines_checkcast_arraycopy(
; COMMON: phi i64 [ 0, %arraycopy.slow_region ], [ {{%.*}}, %arraycopy.checkcast.failure ]
; COMMON: invoke hotspotcc void @SharedRuntime_slow_arraycopy_C({{.*}}[ "deopt"(i32 1) ]
; COMMON: arraycopy.result:
; COMMON-NEXT: fence release
; COMMON-NOT: @jeandle.copy

define ptr addrspace(1) @copyof_range_checkcast(ptr addrspace(1) %src, ptr %src_klass, ptr %dest_klass) #0 personality ptr @personality {
entry:
  %dest = call ptr addrspace(1) @jeandle.new_array(ptr null, i32 8, i32 48, i32 16, i32 1000, i1 false, i1 false)
  invoke void @jeandle.copy(ptr addrspace(1) %src, i64 1, ptr addrspace(1) %dest, i64 0, i64 7, ptr %src_klass, ptr %dest_klass, i64 8, i64 8) #6 [ "deopt"(i32 1) ] to label %normal unwind label %exception
normal:
  ret ptr addrspace(1) %dest
exception:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; COMMON-LABEL: define ptr addrspace(1) @copyof_range_checkcast(
; UNINIT: call i32 @StubRoutines_checkcast_arraycopy_uninit(
; INIT: call i32 @StubRoutines_checkcast_arraycopy(
; COMMON: [[OFFSET:%.*]] = phi i64 [ 0, %arraycopy.slow_region ], [ {{%.*}}, %arraycopy.checkcast.failure ]
; COMMON: add i64 1, [[OFFSET]]
; COMMON: sub i64 7, [[OFFSET]]
; COMMON: invoke hotspotcc void @SharedRuntime_slow_arraycopy_C({{.*}}[ "deopt"(i32 1) ]
; COMMON: arraycopy.result:
; COMMON-NEXT: fence release
; COMMON-NOT: @jeandle.copy

; Analyze both sites before changing the shared exceptional CFG, and retain
; each destination's publication ordering after expanding both copies.
define ptr addrspace(1) @two_copies(ptr addrspace(1) %src) #0 personality ptr @personality {
entry:
  %first = call ptr addrspace(1) @jeandle.new_array(ptr null, i32 8, i32 48, i32 16, i32 1000, i1 false, i1 false)
  invoke void @jeandle.copy(ptr addrspace(1) %src, i64 0, ptr addrspace(1) %first, i64 0, i64 8, ptr null, ptr null, i64 8, i64 8) #1 [ "deopt"(i32 1) ] to label %second_copy unwind label %exception
second_copy:
  %second = call ptr addrspace(1) @jeandle.new_array(ptr null, i32 8, i32 48, i32 16, i32 1000, i1 false, i1 false)
  invoke void @jeandle.copy(ptr addrspace(1) %first, i64 1, ptr addrspace(1) %second, i64 0, i64 7, ptr null, ptr null, i64 8, i64 8) #2 [ "deopt"(i32 1) ] to label %normal unwind label %exception
normal:
  ret ptr addrspace(1) %second
exception:
  %site = phi i32 [ 1, %entry ], [ 2, %second_copy ]
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; COMMON-LABEL: define ptr addrspace(1) @two_copies(
; UNINIT: call void @StubRoutines_arrayof_oop_disjoint_arraycopy_uninit(
; INIT: call void @StubRoutines_arrayof_oop_disjoint_arraycopy(
; COMMON: arraycopy.result:
; COMMON-NEXT: fence release
; COMMON: second_copy:
; UNINIT: call void @StubRoutines_oop_disjoint_arraycopy_uninit(
; INIT: call void @StubRoutines_oop_disjoint_arraycopy(
; COMMON: arraycopy.result{{[0-9]+}}:
; COMMON-NEXT: fence release
; COMMON-NOT: @jeandle.copy

attributes #0 = { "java-method"="0" }
attributes #1 = { "jeandle.copy.kind"="copyof" "jeandle.copy.validated" "jeandle.copy.negative-length-guard" "jeandle.copy.tightly-coupled-allocation" }
attributes #2 = { "jeandle.copy.kind"="copyof-range" "jeandle.copy.validated" "jeandle.copy.negative-length-guard" "jeandle.copy.tightly-coupled-allocation" }
attributes #3 = { "jeandle.copy.kind"="arraycopy" "jeandle.copy.negative-length-guard" "jeandle.copy.tightly-coupled-allocation" }
attributes #4 = { "jeandle.copy.kind"="arraycopy" "jeandle.copy.negative-length-guard" }
attributes #5 = { "jeandle.copy.kind"="copyof" "jeandle.copy.negative-length-guard" "jeandle.copy.tightly-coupled-allocation" }
attributes #6 = { "jeandle.copy.kind"="copyof-range" "jeandle.copy.negative-length-guard" "jeandle.copy.tightly-coupled-allocation" }
!java-method-compilation = !{}
!current-thread = !{!0}
!0 = !{!"r15"}
