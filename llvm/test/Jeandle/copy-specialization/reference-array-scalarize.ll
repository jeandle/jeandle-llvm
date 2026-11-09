; RUN: opt -S -verify-each -passes='copy-specialization' -jeandle-vm-callback-log=%S/Inputs/uninitialized-destination.cblog %s | FileCheck %s --check-prefixes=COMMON,SCALAR,NARROW
; RUN: sed 's/@heapOopSize = constant i32 4/@heapOopSize = constant i32 8/;s/@arrayOopDesc.element_size.object = constant i32 4/@arrayOopDesc.element_size.object = constant i32 8/' %s | opt -S -verify-each -passes='copy-specialization' -jeandle-vm-callback-log=%S/Inputs/uninitialized-destination.cblog | FileCheck %s --check-prefixes=COMMON,SCALAR,WIDE
; RUN: sed 's/@VMOptions.ReduceInitialCardMarks = constant i1 true/@VMOptions.ReduceInitialCardMarks = constant i1 false/' %s | opt -S -verify-each -passes='copy-specialization' -jeandle-vm-callback-log=%S/Inputs/uninitialized-destination.cblog | FileCheck %s --check-prefixes=COMMON,BULK
; RUN: sed '/^@VMOptions.ReduceInitialCardMarks/d' %s | opt -S -verify-each -passes='copy-specialization' -jeandle-vm-callback-log=%S/Inputs/uninitialized-destination.cblog | FileCheck %s --check-prefixes=COMMON,BULK
; RUN: opt -S -verify-each -passes='function(copy-specialization,insert-gc-barriers)' -jeandle-vm-callback-log=%S/Inputs/uninitialized-destination.cblog %s | FileCheck %s --check-prefix=GC
; RUN: opt -S -verify-each -passes='copy-specialization' %s | FileCheck %s --check-prefix=NO-VM

target datalayout = "e-p:64:64-p3:32:32"
@VMOptions.ReduceInitialCardMarks = constant i1 true
@VMOptions.ArrayCopyLoadStoreMaxElem = constant i32 8
@arrayOopDesc.element_size.object = constant i32 4
@heapOopSize = constant i32 4
@WordSize = constant i64 8
@personality = global ptr null

declare "java-klass"="202" ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32, i1, i1)
declare void @jeandle.copy(ptr addrspace(1), i64, ptr addrspace(1), i64, i64, ptr, ptr, i64, i64)
declare void @StubRoutines_arrayof_oop_disjoint_arraycopy(ptr addrspace(1), ptr addrspace(1), i64)
declare void @StubRoutines_arrayof_oop_disjoint_arraycopy_uninit(ptr addrspace(1), ptr addrspace(1), i64)
declare void @StubRoutines_oop_disjoint_arraycopy(ptr addrspace(1), ptr addrspace(1), i64)
declare void @StubRoutines_oop_disjoint_arraycopy_uninit(ptr addrspace(1), ptr addrspace(1), i64)
declare hotspotcc void @SharedRuntime_slow_arraycopy_C(ptr addrspace(1), i32, ptr addrspace(1), i32, i32, ptr)
declare hotspotcc void @jeandle.pre_barrier(ptr addrspace(1))
declare hotspotcc void @jeandle.post_barrier(ptr addrspace(1), ptr addrspace(1))

define ptr addrspace(1) @small_copyof(ptr addrspace(1) "java-klass"="201" %src) #0 personality ptr @personality {
entry:
  %dest = call ptr addrspace(1) @jeandle.new_array(ptr null, i32 8, i32 80, i32 16, i32 1000, i1 false, i1 false)
  invoke void @jeandle.copy(ptr addrspace(1) %src, i64 0, ptr addrspace(1) %dest, i64 0, i64 8, ptr null, ptr null, i64 8, i64 8) #1 [ "deopt"(i32 0) ] to label %normal unwind label %exception
normal:
  ret ptr addrspace(1) %dest
exception:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; COMMON-LABEL: define ptr addrspace(1) @small_copyof(
; NO-VM-LABEL: define ptr addrspace(1) @small_copyof(
; NO-VM-COUNT-8: load atomic volatile ptr addrspace(3)
; NO-VM: arraycopy.ideal.result:
; NO-VM-NEXT: fence release
; NO-VM-NEXT: br label %normal
; NARROW: load atomic volatile ptr addrspace(3), ptr addrspace(1) {{%.*}} unordered
; NARROW: store atomic ptr addrspace(3) {{%.*}}, ptr addrspace(1) {{%.*}} unordered
; WIDE: load atomic volatile ptr addrspace(1), ptr addrspace(1) {{%.*}} unordered
; WIDE: store atomic ptr addrspace(1) {{%.*}}, ptr addrspace(1) {{%.*}} unordered
; SCALAR-NOT: @StubRoutines_
; SCALAR: arraycopy.ideal.result:
; SCALAR-NEXT: fence release
; SCALAR-NEXT: br label %normal
; BULK-NOT: load atomic
; BULK: call void @StubRoutines_arrayof_oop_disjoint_arraycopy_uninit(
; BULK: arraycopy.result:
; BULK-NEXT: fence release
; COMMON-NOT: @jeandle.copy

; GC-LABEL: define ptr addrspace(1) @small_copyof(
; GC: [[VALUE:%.*]] = load atomic volatile ptr addrspace(3), ptr addrspace(1) {{%.*}} unordered
; GC-NEXT: call hotspotcc void @jeandle.pre_barrier(ptr addrspace(1) [[DEST:%.*]])
; GC-NEXT: store atomic ptr addrspace(3) [[VALUE]], ptr addrspace(1) [[DEST]] unordered
; GC-NEXT: [[OOP:%.*]] = addrspacecast ptr addrspace(3) [[VALUE]] to ptr addrspace(1)
; GC-NEXT: call hotspotcc void @jeandle.post_barrier(ptr addrspace(1) [[DEST]], ptr addrspace(1) [[OOP]])

define ptr addrspace(1) @small_range(ptr addrspace(1) "java-klass"="201" %src) #0 personality ptr @personality {
entry:
  %dest = call ptr addrspace(1) @jeandle.new_array(ptr null, i32 9, i32 88, i32 16, i32 1000, i1 false, i1 false)
  invoke void @jeandle.copy(ptr addrspace(1) %src, i64 1, ptr addrspace(1) %dest, i64 0, i64 1, ptr null, ptr null, i64 2, i64 9) #2 [ "deopt"(i32 0) ] to label %normal unwind label %exception
normal:
  ret ptr addrspace(1) %dest
exception:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; COMMON-LABEL: define ptr addrspace(1) @small_range(
; NARROW: getelementptr i8, ptr addrspace(1) {{%.*}}, i64 4
; WIDE: getelementptr i8, ptr addrspace(1) {{%.*}}, i64 8
; SCALAR: load atomic volatile ptr addrspace({{[13]}})
; SCALAR: store atomic ptr addrspace({{[13]}})
; SCALAR: arraycopy.ideal.result:
; SCALAR-NEXT: fence release
; BULK: call void @StubRoutines_oop_disjoint_arraycopy_uninit(
; BULK: arraycopy.result:
; BULK-NEXT: fence release
; COMMON-NOT: @jeandle.copy

define ptr addrspace(1) @empty_copyof(ptr addrspace(1) "java-klass"="201" %src) #0 personality ptr @personality {
entry:
  %dest = call ptr addrspace(1) @jeandle.new_array(ptr null, i32 0, i32 16, i32 16, i32 1000, i1 false, i1 false)
  invoke void @jeandle.copy(ptr addrspace(1) %src, i64 0, ptr addrspace(1) %dest, i64 0, i64 0, ptr null, ptr null, i64 8, i64 0) #1 [ "deopt"(i32 0) ] to label %normal unwind label %exception
normal:
  ret ptr addrspace(1) %dest
exception:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; COMMON-LABEL: define ptr addrspace(1) @empty_copyof(
; SCALAR-NOT: load atomic
; SCALAR: arraycopy.ideal.result:
; SCALAR-NEXT: fence release
; BULK: arraycopy.result:
; BULK-NEXT: fence release
; COMMON-NOT: @jeandle.copy

define ptr addrspace(1) @large_copyof(ptr addrspace(1) "java-klass"="201" %src) #0 personality ptr @personality {
entry:
  %dest = call ptr addrspace(1) @jeandle.new_array(ptr null, i32 9, i32 88, i32 16, i32 1000, i1 false, i1 false)
  invoke void @jeandle.copy(ptr addrspace(1) %src, i64 0, ptr addrspace(1) %dest, i64 0, i64 9, ptr null, ptr null, i64 9, i64 9) #1 [ "deopt"(i32 0) ] to label %normal unwind label %exception
normal:
  ret ptr addrspace(1) %dest
exception:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; COMMON-LABEL: define ptr addrspace(1) @large_copyof(
; COMMON-NOT: load atomic
; COMMON: call void @StubRoutines_arrayof_oop_disjoint_arraycopy_uninit(
; COMMON: arraycopy.result:
; COMMON-NEXT: fence release
; COMMON-NOT: @jeandle.copy

define void @existing_destination(ptr addrspace(1) "java-klass"="201" %src, ptr addrspace(1) "java-klass"="202" %dest) #0 personality ptr @personality {
entry:
  invoke void @jeandle.copy(ptr addrspace(1) %src, i64 0, ptr addrspace(1) %dest, i64 0, i64 8, ptr null, ptr null, i64 8, i64 8) #3 [ "deopt"(i32 0) ] to label %normal unwind label %exception
normal:
  ret void
exception:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; COMMON-LABEL: define void @existing_destination(
; COMMON-NOT: load atomic
; COMMON: call void @StubRoutines_arrayof_oop_disjoint_arraycopy(
; COMMON-NOT: fence
; COMMON-NOT: @jeandle.copy

; Validated System.arraycopy into a fresh array shares the same safe policy.
define ptr addrspace(1) @fresh_arraycopy(ptr addrspace(1) "java-klass"="201" %src) #0 personality ptr @personality {
entry:
  %dest = call "java-klass"="202" ptr addrspace(1) @jeandle.new_array(ptr null, i32 8, i32 80, i32 16, i32 1000, i1 false, i1 false)
  invoke void @jeandle.copy(ptr addrspace(1) %src, i64 0, ptr addrspace(1) %dest, i64 0, i64 8, ptr null, ptr null, i64 8, i64 8) #4 [ "deopt"(i32 0) ] to label %normal unwind label %exception
normal:
  ret ptr addrspace(1) %dest
exception:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; COMMON-LABEL: define ptr addrspace(1) @fresh_arraycopy(
; SCALAR: load atomic volatile ptr addrspace({{[13]}})
; SCALAR: store atomic ptr addrspace({{[13]}})
; SCALAR: arraycopy.ideal.result:
; SCALAR-NEXT: fence release
; BULK-NOT: load atomic
; BULK: call void @StubRoutines_arrayof_oop_disjoint_arraycopy_uninit(
; BULK: arraycopy.result:
; BULK-NEXT: fence release
; COMMON-NOT: @jeandle.copy

attributes #0 = { "java-method"="0" }
attributes #1 = { "jeandle.copy.kind"="copyof" "jeandle.copy.validated" "jeandle.copy.negative-length-guard" "jeandle.copy.tightly-coupled-allocation" }
attributes #2 = { "jeandle.copy.kind"="copyof-range" "jeandle.copy.validated" "jeandle.copy.negative-length-guard" "jeandle.copy.tightly-coupled-allocation" }
attributes #3 = { "jeandle.copy.kind"="arraycopy" "jeandle.copy.validated" "jeandle.copy.negative-length-guard" }
attributes #4 = { "jeandle.copy.kind"="arraycopy" "jeandle.copy.validated" "jeandle.copy.negative-length-guard" "jeandle.copy.tightly-coupled-allocation" }
!java-method-compilation = !{}
!current-thread = !{!0}
!0 = !{!"r15"}
