; RUN: opt -S -verify-each -passes=copy-specialization %s | FileCheck %s --check-prefixes=COMMON,NARROW
; RUN: sed 's/constant i32 4$/constant i32 8/' %s | opt -S -verify-each -passes=copy-specialization | FileCheck %s --check-prefixes=COMMON,WIDE
; RUN: sed 's/@Jeandle.FreshArrayCopyRequiresGCBarriers = constant i1 false/@Jeandle.FreshArrayCopyRequiresGCBarriers = constant i1 true/' %s | opt -S -verify-each -passes=copy-specialization | FileCheck %s --check-prefix=KEEP
; RUN: sed '/^@Jeandle.FreshArrayCopyRequiresGCBarriers/d' %s | opt -S -verify-each -passes=copy-specialization | FileCheck %s --check-prefix=KEEP
; RUN: sed 's/@VMOptions.ReduceBulkZeroing = constant i1 true/@VMOptions.ReduceBulkZeroing = constant i1 false/' %s | opt -S -verify-each -passes=copy-specialization | FileCheck %s --check-prefix=INITIALIZED
; RUN: sed '/^declare void @StubRoutines_arrayof_jint_disjoint_arraycopy/d' %s | opt -S -verify-each -passes=copy-specialization | FileCheck %s --check-prefix=KEEP
; RUN: sed 's/constant i32 4$/constant i32 8/; /^declare void @StubRoutines_arrayof_jlong_disjoint_arraycopy/d' %s | opt -S -verify-each -passes=copy-specialization | FileCheck %s --check-prefix=KEEP


@Jeandle.FreshArrayCopyRequiresGCBarriers = constant i1 false
@VMOptions.ReduceBulkZeroing = constant i1 true
@VMOptions.ArrayCopyLoadStoreMaxElem = constant i32 0
@heapOopSize = constant i32 4
@arrayOopDesc.element_size.object = constant i32 4
@WordSize = constant i64 8
@personality = global ptr null

declare ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32, i1, i1)
declare void @jeandle.copy(ptr addrspace(1), i64, ptr addrspace(1), i64, i64, ptr, ptr, i64, i64)
declare void @StubRoutines_arrayof_jint_disjoint_arraycopy(ptr addrspace(1), ptr addrspace(1), i64)
declare void @StubRoutines_arrayof_jlong_disjoint_arraycopy(ptr addrspace(1), ptr addrspace(1), i64)
declare void @StubRoutines_arrayof_oop_disjoint_arraycopy_uninit(ptr addrspace(1), ptr addrspace(1), i64)
declare void @StubRoutines_arrayof_oop_disjoint_arraycopy(ptr addrspace(1), ptr addrspace(1), i64)
declare i32 @StubRoutines_checkcast_arraycopy_uninit(ptr addrspace(1), ptr addrspace(1), i64, i64, ptr)
declare i32 @StubRoutines_checkcast_arraycopy(ptr addrspace(1), ptr addrspace(1), i64, i64, ptr)
declare hotspotcc void @SharedRuntime_slow_arraycopy_C(ptr addrspace(1), i32, ptr addrspace(1), i32, i32, ptr)
declare i1 @jeandle.check_klass_subtype(ptr, ptr)
declare ptr @jeandle.load_array_element_klass(ptr)
declare void @safepoint() nounwind willreturn memory(none)

define ptr addrspace(1) @copyof(ptr addrspace(1) %src, ptr %escape, ptr %sk, ptr %dk) #0 personality ptr @personality {
entry:
  %dst = call ptr addrspace(1) @jeandle.new_array(ptr null, i32 16, i32 144, i32 16, i32 1000, i1 false, i1 false)
  invoke void @jeandle.copy(ptr addrspace(1) %src, i64 0, ptr addrspace(1) %dst, i64 0, i64 16, ptr %sk, ptr %dk, i64 16, i64 16) #1 [ "deopt"(i32 0) ] to label %done unwind label %exception
done:
  ret ptr addrspace(1) %dst
exception:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; COMMON-LABEL: define ptr addrspace(1) @copyof(
; NARROW: call void @StubRoutines_arrayof_jint_disjoint_arraycopy(
; WIDE: call void @StubRoutines_arrayof_jlong_disjoint_arraycopy(
; COMMON: call hotspotcc void @jeandle.membar_allocation_init(ptr addrspace(1) %dst)
; KEEP-LABEL: define ptr addrspace(1) @copyof(
; KEEP: call void @StubRoutines_arrayof_oop_disjoint_arraycopy_uninit(
; INITIALIZED-LABEL: define ptr addrspace(1) @copyof(
; INITIALIZED: call void @StubRoutines_arrayof_oop_disjoint_arraycopy(

define ptr addrspace(1) @range(ptr addrspace(1) %src, ptr %escape, ptr %sk, ptr %dk) #0 personality ptr @personality {
entry:
  %dst = call ptr addrspace(1) @jeandle.new_array(ptr null, i32 16, i32 144, i32 16, i32 1000, i1 false, i1 false)
  invoke void @jeandle.copy(ptr addrspace(1) %src, i64 0, ptr addrspace(1) %dst, i64 0, i64 16, ptr %sk, ptr %dk, i64 16, i64 16) #2 [ "deopt"(i32 0) ] to label %done unwind label %exception
done:
  ret ptr addrspace(1) %dst
exception:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; COMMON-LABEL: define ptr addrspace(1) @range(
; NARROW: call void @StubRoutines_arrayof_jint_disjoint_arraycopy(
; WIDE: call void @StubRoutines_arrayof_jlong_disjoint_arraycopy(
; COMMON: call hotspotcc void @jeandle.membar_allocation_init(ptr addrspace(1) %dst)
; KEEP-LABEL: define ptr addrspace(1) @range(
; KEEP: call void @StubRoutines_arrayof_oop_disjoint_arraycopy_uninit(
; INITIALIZED-LABEL: define ptr addrspace(1) @range(
; INITIALIZED: call void @StubRoutines_arrayof_oop_disjoint_arraycopy(

define ptr addrspace(1) @clone(ptr addrspace(1) %src, ptr %escape, ptr %sk, ptr %dk) #0 personality ptr @personality {
entry:
  %dst = call ptr addrspace(1) @jeandle.new_array(ptr null, i32 16, i32 144, i32 16, i32 1000, i1 false, i1 false)
  invoke void @jeandle.copy(ptr addrspace(1) %src, i64 0, ptr addrspace(1) %dst, i64 0, i64 16, ptr %sk, ptr %dk, i64 16, i64 16) #3 [ "deopt"(i32 0) ] to label %done unwind label %exception
done:
  ret ptr addrspace(1) %dst
exception:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; COMMON-LABEL: define ptr addrspace(1) @clone(
; NARROW: call void @StubRoutines_arrayof_jint_disjoint_arraycopy(
; WIDE: call void @StubRoutines_arrayof_jlong_disjoint_arraycopy(
; COMMON: call hotspotcc void @jeandle.membar_allocation_init(ptr addrspace(1) %dst)
; KEEP-LABEL: define ptr addrspace(1) @clone(
; KEEP: call void @StubRoutines_arrayof_oop_disjoint_arraycopy_uninit(
; INITIALIZED-LABEL: define ptr addrspace(1) @clone(
; INITIALIZED: call void @StubRoutines_arrayof_oop_disjoint_arraycopy(

define ptr addrspace(1) @interrupted(ptr addrspace(1) %src, ptr %escape, ptr %sk, ptr %dk) #0 personality ptr @personality {
entry:
  %dst = call ptr addrspace(1) @jeandle.new_array(ptr null, i32 16, i32 144, i32 16, i32 1000, i1 false, i1 false)
  call void @safepoint()
  invoke void @jeandle.copy(ptr addrspace(1) %src, i64 0, ptr addrspace(1) %dst, i64 0, i64 16, ptr %sk, ptr %dk, i64 16, i64 16) #1 [ "deopt"(i32 0) ] to label %done unwind label %exception
done:
  ret ptr addrspace(1) %dst
exception:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; COMMON-LABEL: define ptr addrspace(1) @interrupted(
; COMMON-NOT: call void @StubRoutines_arrayof_jint
; COMMON-NOT: call void @StubRoutines_arrayof_jlong
; COMMON: call void @StubRoutines_arrayof_oop_disjoint_arraycopy_uninit(

define ptr addrspace(1) @published(ptr addrspace(1) %src, ptr %escape, ptr %sk, ptr %dk) #0 personality ptr @personality {
entry:
  %dst = call ptr addrspace(1) @jeandle.new_array(ptr null, i32 16, i32 144, i32 16, i32 1000, i1 false, i1 false)
  store ptr addrspace(1) %dst, ptr %escape
  invoke void @jeandle.copy(ptr addrspace(1) %src, i64 0, ptr addrspace(1) %dst, i64 0, i64 16, ptr %sk, ptr %dk, i64 16, i64 16) #1 [ "deopt"(i32 0) ] to label %done unwind label %exception
done:
  ret ptr addrspace(1) %dst
exception:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; COMMON-LABEL: define ptr addrspace(1) @published(
; COMMON-NOT: call void @StubRoutines_arrayof_jint
; COMMON-NOT: call void @StubRoutines_arrayof_jlong
; COMMON: call void @StubRoutines_arrayof_oop_disjoint_arraycopy_uninit(

define ptr addrspace(1) @checked(ptr addrspace(1) %src, ptr %escape, ptr %sk, ptr %dk) #0 personality ptr @personality {
entry:
  %dst = call ptr addrspace(1) @jeandle.new_array(ptr null, i32 16, i32 144, i32 16, i32 1000, i1 false, i1 false)
  invoke void @jeandle.copy(ptr addrspace(1) %src, i64 0, ptr addrspace(1) %dst, i64 0, i64 16, ptr %sk, ptr %dk, i64 16, i64 16) #4 [ "deopt"(i32 0) ] to label %done unwind label %exception
done:
  ret ptr addrspace(1) %dst
exception:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; COMMON-LABEL: define ptr addrspace(1) @checked(
; NARROW: call void @StubRoutines_arrayof_jint_disjoint_arraycopy(
; WIDE: call void @StubRoutines_arrayof_jlong_disjoint_arraycopy(
; COMMON: call hotspotcc void @jeandle.membar_allocation_init(ptr addrspace(1) %dst)
; KEEP-LABEL: define ptr addrspace(1) @checked(
; KEEP: call void @StubRoutines_arrayof_oop_disjoint_arraycopy_uninit(
; INITIALIZED-LABEL: define ptr addrspace(1) @checked(
; INITIALIZED: call void @StubRoutines_arrayof_oop_disjoint_arraycopy(

define ptr addrspace(1) @ordinary(ptr addrspace(1) %src, ptr %escape, ptr %sk, ptr %dk) #0 personality ptr @personality {
entry:
  %dst = call ptr addrspace(1) @jeandle.new_array(ptr null, i32 16, i32 144, i32 16, i32 1000, i1 false, i1 false)
  invoke void @jeandle.copy(ptr addrspace(1) %src, i64 0, ptr addrspace(1) %dst, i64 0, i64 16, ptr %sk, ptr %dk, i64 16, i64 16) #5 [ "deopt"(i32 0) ] to label %done unwind label %exception
done:
  ret ptr addrspace(1) %dst
exception:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; COMMON-LABEL: define ptr addrspace(1) @ordinary(
; COMMON-NOT: call void @StubRoutines_arrayof_jint
; COMMON-NOT: call void @StubRoutines_arrayof_jlong
; COMMON: invoke hotspotcc void @SharedRuntime_slow_arraycopy_C(

attributes #0 = { "java-method"="0" }
attributes #1 = { "jeandle.copy.kind"="copyof" "jeandle.copy.validated" "jeandle.copy.negative-length-guard" "jeandle.copy.tightly-coupled-allocation" }
attributes #2 = { "jeandle.copy.kind"="copyof-range" "jeandle.copy.validated" "jeandle.copy.negative-length-guard" "jeandle.copy.tightly-coupled-allocation" }
attributes #3 = { "jeandle.copy.kind"="clone-reference-array" "jeandle.copy.negative-length-guard" "jeandle.copy.tightly-coupled-allocation" }
attributes #4 = { "jeandle.copy.kind"="copyof" "jeandle.copy.negative-length-guard" "jeandle.copy.tightly-coupled-allocation" }
attributes #5 = { "jeandle.copy.kind"="arraycopy" "jeandle.copy.validated" "jeandle.copy.negative-length-guard" "jeandle.copy.tightly-coupled-allocation" }
!java-method-compilation = !{}
!current-thread = !{!0}
!0 = !{!"r15"}
