; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" -jeandle-vm-callback-log=%S/Inputs/788_copy_fold_kind_matrix.cblog %s | FileCheck %s

; Kind matrix: copyof-range folds virtual-to-virtual (transferring a
; sub-range into a fresh destination) and clone-reference-array folds with a
; concrete reference-array source whose bounds proof is the frontend shape
; arg4 == arg7 (the length IS the source length) with srcPos == 0.

target datalayout = "e-p:64:64-p3:32:32"

@arrayOopDesc.element_size.object = constant i32 4

declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32, i1, i1)
declare void @jeandle.copy(ptr addrspace(1), i64, ptr addrspace(1), i64, i64, ptr, ptr, i64, i64)
declare i32 @__gxx_personality_v0(...)

define i32 @copyof_range_v2v() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %src = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
            ptr inttoptr (i64 12345 to ptr), i32 4, i32 32, i32 16, i32 1048576, i1 false, i1 false)
         to label %init unwind label %u
init:
  %sb = getelementptr inbounds i8, ptr addrspace(1) %src, i32 16
  %s1 = getelementptr inbounds i32, ptr addrspace(1) %sb, i64 1
  %s2 = getelementptr inbounds i32, ptr addrspace(1) %sb, i64 2
  store atomic i32 20, ptr addrspace(1) %s1 unordered, align 4
  store atomic i32 30, ptr addrspace(1) %s2 unordered, align 4
  %dest = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
            ptr inttoptr (i64 12345 to ptr), i32 2, i32 24, i32 16, i32 1048576, i1 false, i1 false)
         to label %do_copy unwind label %u
do_copy:
  invoke void @jeandle.copy(ptr addrspace(1) %src, i64 1, ptr addrspace(1) %dest, i64 0, i64 2,
                            ptr null, ptr null, i64 4, i64 2)
      #0 [ "deopt"(i32 99, i32 99, i64 12, ptr addrspace(1) %src) ]
      to label %read unwind label %u
read:
  %db = getelementptr inbounds i8, ptr addrspace(1) %dest, i32 16
  %d0 = getelementptr inbounds i32, ptr addrspace(1) %db, i64 0
  %d1 = getelementptr inbounds i32, ptr addrspace(1) %db, i64 1
  %v0 = load atomic i32, ptr addrspace(1) %d0 unordered, align 4
  %v1 = load atomic i32, ptr addrspace(1) %d1 unordered, align 4
  %r = add i32 %v0, %v1
  ret i32 %r
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

attributes #0 = { "jeandle.copy.kind"="copyof-range" "jeandle.copy.validated" }

define ptr addrspace(1) @clone_ref_array_concrete(ptr addrspace(1) "java-klass"="22222" %src) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %dest = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
            ptr inttoptr (i64 22222 to ptr), i32 2, i32 32, i32 16, i32 1048576, i1 false, i1 false)
         to label %do_clone unwind label %u2
do_clone:
  invoke void @jeandle.copy(ptr addrspace(1) %src, i64 0, ptr addrspace(1) %dest, i64 0, i64 2,
                            ptr null, ptr null, i64 2, i64 2)
      #1 [ "deopt"(i32 99, i32 99, i64 12, ptr addrspace(1) null) ]
      to label %read2 unwind label %u2
read2:
  %db = getelementptr inbounds i8, ptr addrspace(1) %dest, i32 16
  %v0 = load atomic ptr addrspace(3), ptr addrspace(1) %db unordered, align 4
  %w0 = addrspacecast ptr addrspace(3) %v0 to ptr addrspace(1)
  ret ptr addrspace(1) %w0
u2:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

attributes #1 = { "jeandle.copy.kind"="clone-reference-array" "jeandle.copy.negative-length-guard" }

; copyof-range: the sub-range transfer folds and both arrays are eliminated.
; CHECK-LABEL: define i32 @copyof_range_v2v
; CHECK-NOT: jeandle.new_array
; CHECK-NOT: jeandle.copy
; CHECK: %r = add i32 20, 30
; CHECK: ret i32 %r
;
; clone-reference-array: element loads from the concrete source, destination
; eliminated, first element returned.
; CHECK-LABEL: define ptr addrspace(1) @clone_ref_array_concrete
; CHECK-NOT: jeandle.new_array
; CHECK-NOT: jeandle.copy
; The narrow element load and its AS1 semantic cast.
; CHECK: %[[CA:.*]] = getelementptr inbounds i8, ptr addrspace(1) %src, i64 16
; CHECK: %[[CL:.*]] = load atomic ptr addrspace(3), ptr addrspace(1) %[[CA]] unordered, align 4
; CHECK: ret ptr addrspace(1) {{%.*}}

!java-method-compilation = !{}
