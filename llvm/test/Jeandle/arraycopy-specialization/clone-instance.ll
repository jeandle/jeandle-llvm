; RUN: opt -S -passes="function(arraycopy-specialization),java-operation-lower<phase=1>" -jeandle-vm-callback-log=%S/Inputs/clone-instance.cblog %s 2>&1 | FileCheck %s --check-prefix=IR
; RUN: opt -S -passes="function(arraycopy-specialization),java-operation-lower<phase=1>" -jeandle-vm-callback-log=%S/Inputs/clone-instance.cblog %s 2>&1 | llc -mtriple=aarch64-linux-gnu -O2 -o - | FileCheck %s --check-prefix=AARCH64
; RUN: opt -S -passes="function(arraycopy-specialization),java-operation-lower<phase=1>" -jeandle-vm-callback-log=%S/Inputs/clone-instance-gc-barrier.cblog %s 2>&1 | FileCheck %s --check-prefix=BARRIER
; RUN: opt -S -passes="function(arraycopy-specialization,insert-gc-barriers),java-operation-lower<phase=1>" -jeandle-vm-callback-log=%S/Inputs/clone-instance.cblog %s 2>&1 | FileCheck %s --check-prefix=GC-BARRIER

target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-p3:32:32:32-i8:8:32-i16:16:32-i64:64-i128:128-n32:64-S128-Fn32"
target triple = "aarch64-unknown-linux-gnu"

@ArrayCopyLoadStoreMaxElem = constant i32 8
@heapOopSize = constant i32 4
@UseG1GC = constant i1 false
@ReduceInitialCardMarks = constant i1 false

declare void @jeandle.arraycopy(ptr addrspace(1), i64,
                                ptr addrspace(1), i64, i64,
                                ptr, ptr, i64, i64)

declare void @StubRoutines_jlong_disjoint_arraycopy(
    ptr addrspace(1), ptr addrspace(1), i64)
declare hotspotcc void @jeandle.pre_barrier(ptr addrspace(1))
declare hotspotcc void @jeandle.post_barrier(
    ptr addrspace(1), ptr addrspace(1))

define hotspotcc void @jeandle.clone_at_expansion(
    ptr addrspace(1) %src, i64 %src_offset,
    ptr addrspace(1) %dest, i64 %dest_offset, i64 %length,
    i1 %is_clone_inst) #2 {
entry:
  %payload_src = getelementptr i8, ptr addrspace(1) %src, i64 %src_offset
  %payload_dest = getelementptr i8, ptr addrspace(1) %dest, i64 %dest_offset
  call void @StubRoutines_jlong_disjoint_arraycopy(
      ptr addrspace(1) %payload_src, ptr addrspace(1) %payload_dest,
      i64 %length)
  ret void
}

define void @clone_exact(
    ptr addrspace(1) "java-klass"="42" "java-klass-exact" %src,
    ptr addrspace(1) %dest) #0 gc "hotspotgc" {
entry:
  call void @jeandle.arraycopy(
      ptr addrspace(1) %src, i64 8, ptr addrspace(1) %dest, i64 8, i64 4,
      ptr null, ptr null, i64 32, i64 32) #1
  ret void
}

; IR-LABEL: define void @clone_exact(
; IR: [[SRC0:%.*]] = getelementptr inbounds i8, ptr addrspace(1) %src, i64 12
; IR: [[DEST0:%.*]] = getelementptr inbounds i8, ptr addrspace(1) %dest, i64 12
; IR: [[LOAD0:%.*]] = load atomic volatile i32, ptr addrspace(1) [[SRC0]] unordered
; IR: store atomic i32 [[LOAD0]], ptr addrspace(1) [[DEST0]] unordered
; IR: [[SRC1:%.*]] = getelementptr inbounds i8, ptr addrspace(1) %src, i64 16
; IR: [[DEST1:%.*]] = getelementptr inbounds i8, ptr addrspace(1) %dest, i64 16
; IR: [[LOAD1:%.*]] = load atomic volatile i64, ptr addrspace(1) [[SRC1]] unordered
; IR: store atomic i64 [[LOAD1]], ptr addrspace(1) [[DEST1]] unordered
; IR: [[SRC2:%.*]] = getelementptr inbounds i8, ptr addrspace(1) %src, i64 24
; IR: [[DEST2:%.*]] = getelementptr inbounds i8, ptr addrspace(1) %dest, i64 24
; IR: [[LOAD2:%.*]] = load atomic volatile ptr addrspace(3), ptr addrspace(1) [[SRC2]] unordered
; IR: store atomic ptr addrspace(3) [[LOAD2]], ptr addrspace(1) [[DEST2]] unordered
; IR-NOT: call void @jeandle.arraycopy
; IR: ret void

; AARCH64-LABEL: clone_exact:
; AARCH64: ldr w[[INT:[0-9]+]], [x0, #12]
; AARCH64: str w[[INT]], [x1, #12]
; AARCH64: ldr x[[LONG:[0-9]+]], [x0, #16]
; AARCH64: str x[[LONG]], [x1, #16]

; GC-BARRIER-LABEL: define void @clone_exact(
; GC-BARRIER: [[OOP:%.*]] = load atomic volatile ptr addrspace(3), ptr addrspace(1) [[SRC:%.*]] unordered
; GC-BARRIER-NEXT: call hotspotcc void @jeandle.pre_barrier(ptr addrspace(1) [[DEST:%.*]])
; GC-BARRIER-NEXT: store atomic ptr addrspace(3) [[OOP]], ptr addrspace(1) [[DEST]] unordered
; GC-BARRIER-NEXT: [[DECODED:%.*]] = addrspacecast ptr addrspace(3) [[OOP]] to ptr addrspace(1)
; GC-BARRIER-NEXT: call hotspotcc void @jeandle.post_barrier(ptr addrspace(1) [[DEST]], ptr addrspace(1) [[DECODED]])

; BARRIER-LABEL: define void @clone_exact(
; BARRIER: call void @StubRoutines_jlong_disjoint_arraycopy
; BARRIER: ret void

define void @clone_nonexact_decline(
    ptr addrspace(1) "java-klass"="43" %src,
    ptr addrspace(1) %dest) #0 gc "hotspotgc" {
entry:
  call void @jeandle.arraycopy(
      ptr addrspace(1) %src, i64 8, ptr addrspace(1) %dest, i64 8, i64 4,
      ptr null, ptr null, i64 32, i64 32) #1
  ret void
}

; IR-LABEL: define void @clone_nonexact_decline(
; IR: call void @StubRoutines_jlong_disjoint_arraycopy
; IR: ret void

define void @clone_concurrent_subclass_decline(
    ptr addrspace(1) "java-klass"="44" %src,
    ptr addrspace(1) %dest) #0 gc "hotspotgc" {
entry:
  call void @jeandle.arraycopy(
      ptr addrspace(1) %src, i64 8, ptr addrspace(1) %dest, i64 8, i64 4,
      ptr null, ptr null, i64 32, i64 32) #1
  ret void
}

; IR-LABEL: define void @clone_concurrent_subclass_decline(
; IR: call void @StubRoutines_jlong_disjoint_arraycopy
; IR: ret void

attributes #0 = { "java-method"="0" }
attributes #1 = { "jeandle.arraycopy.kind"="clone-inst" }
attributes #2 = { noinline nounwind "gc-leaf-function" "lower-phase"="1" }

!java-method-compilation = !{}
