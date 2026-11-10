; RUN: opt -S -verify-each -passes="require<partial-escape-analysis>,partial-escape-transform" -jeandle-vm-callback-log=%S/Inputs/770_copy_fold_v2v_full.cblog %s | FileCheck %s
; RUN: sed 's/e-p:64:64/E-p:64:64/' %s | opt -S -verify-each -passes="require<partial-escape-analysis>,partial-escape-transform" -jeandle-vm-callback-log=%S/Inputs/770_copy_fold_v2v_full.cblog | FileCheck %s
; RUN: opt -S -verify-each -passes="partial-escape-iterative" -jeandle-vm-callback-log=%S/Inputs/770_copy_fold_v2v_full.cblog %s | FileCheck %s --check-prefix=ITER
; ITER-LABEL: define i32 @subelement_merge(
; ITER: store atomic i16 21862
; ITER: load atomic i32
; ITER-LABEL: define i32 @subelement_merge_then_copy(
; ITER: store atomic i16 21862
; ITER: load atomic i32

; Primitive array state represents complete elements or groups of complete
; elements. Keep writes to a partial element real at their original store.
target datalayout = "e-p:64:64"

declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32)
declare void @jeandle.copy(ptr addrspace(1), i64, ptr addrspace(1), i64, i64, ptr, ptr, i64, i64)
declare i32 @__gxx_personality_v0(...)

; A short in the upper half of an int must contribute to the merged load.
; CHECK-LABEL: define i32 @subelement_merge(
; CHECK: invoke hotspotcc ptr addrspace(1) @jeandle.new_array
; CHECK: store atomic i16 21862, ptr addrspace(1) %p2 unordered, align 2
; CHECK: %[[VALUE:[^ ]+]] = load atomic i32, ptr addrspace(1) %p0 unordered, align 4
; CHECK: ret i32 %[[VALUE]]
define i32 @subelement_merge(i1 %choose) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %src = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 12345 to ptr), i32 2, i32 24, i32 16, i32 1048576) to label %init unwind label %u
init:
  %p0 = getelementptr inbounds i8, ptr addrspace(1) %src, i64 16
  %p2 = getelementptr inbounds i8, ptr addrspace(1) %src, i64 18
  br i1 %choose, label %left, label %right
left:
  store atomic i32 287454020, ptr addrspace(1) %p0 unordered, align 4
  br label %merge
right:
  store atomic i16 21862, ptr addrspace(1) %p2 unordered, align 2
  br label %merge
merge:
  %v = load atomic i32, ptr addrspace(1) %p0 unordered, align 4
  ret i32 %v
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; Copying the merged source must observe the same partial-element write.
; CHECK-LABEL: define i32 @subelement_merge_then_copy(
; CHECK: invoke hotspotcc ptr addrspace(1) @jeandle.new_array
; CHECK: store atomic i16 21862, ptr addrspace(1) %p2 unordered, align 2
; CHECK: load atomic i32
; CHECK: ret i32
define i32 @subelement_merge_then_copy(i1 %choose) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %src = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 12345 to ptr), i32 2, i32 24, i32 16, i32 1048576) to label %alloc unwind label %u
alloc:
  %dst = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 12345 to ptr), i32 2, i32 24, i32 16, i32 1048576) to label %init unwind label %u
init:
  %p0 = getelementptr inbounds i8, ptr addrspace(1) %src, i64 16
  %p2 = getelementptr inbounds i8, ptr addrspace(1) %src, i64 18
  br i1 %choose, label %left, label %right
left:
  store atomic i32 287454020, ptr addrspace(1) %p0 unordered, align 4
  br label %merge
right:
  store atomic i16 21862, ptr addrspace(1) %p2 unordered, align 2
  br label %merge
merge:
  invoke void @jeandle.copy(ptr addrspace(1) %src, i64 0, ptr addrspace(1) %dst, i64 0, i64 1, ptr null, ptr null, i64 2, i64 2) #0 to label %read unwind label %u
read:
  %dp = getelementptr inbounds i8, ptr addrspace(1) %dst, i64 16
  %v = load atomic i32, ptr addrspace(1) %dp unordered, align 4
  ret i32 %v
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; Starting at an element boundary does not make a partial-element store whole.
; CHECK-LABEL: define i32 @aligned_partial_store(
; CHECK: invoke hotspotcc ptr addrspace(1) @jeandle.new_array
; CHECK: store atomic i16 21862, ptr addrspace(1) %p unordered, align 2
; CHECK: load atomic i32
define i32 @aligned_partial_store() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %src = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 12345 to ptr), i32 2, i32 24, i32 16, i32 1048576) to label %init unwind label %u
init:
  %p = getelementptr inbounds i8, ptr addrspace(1) %src, i64 16
  store atomic i16 21862, ptr addrspace(1) %p unordered, align 2
  %v = load atomic i32, ptr addrspace(1) %p unordered, align 4
  ret i32 %v
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; The typed-element address resolver must not bypass store-span admission.
; CHECK-LABEL: define i32 @typed_partial_store(
; CHECK: invoke hotspotcc ptr addrspace(1) @jeandle.new_array
; CHECK: store atomic i16 21862, ptr addrspace(1) %cell unordered, align 2
; CHECK: load atomic i32
define i32 @typed_partial_store() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %src = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 12345 to ptr), i32 2, i32 24, i32 16, i32 1048576) to label %init unwind label %u
init:
  %base = getelementptr inbounds i8, ptr addrspace(1) %src, i64 16
  %cell = getelementptr inbounds i32, ptr addrspace(1) %base, i64 1
  store atomic i16 21862, ptr addrspace(1) %cell unordered, align 2
  %v = load atomic i32, ptr addrspace(1) %cell unordered, align 4
  ret i32 %v
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; Materialization must replay the old full element before the partial write.
; CHECK-LABEL: define i32 @partial_overwrites_element(
; CHECK: invoke hotspotcc ptr addrspace(1) @jeandle.new_array
; CHECK: store atomic i32 287454020
; CHECK: store atomic i16 21862, ptr addrspace(1) %p2 unordered, align 2
; CHECK: load atomic i32
define i32 @partial_overwrites_element() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %src = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 12345 to ptr), i32 2, i32 24, i32 16, i32 1048576) to label %init unwind label %u
init:
  %p0 = getelementptr inbounds i8, ptr addrspace(1) %src, i64 16
  %p2 = getelementptr inbounds i8, ptr addrspace(1) %src, i64 18
  store atomic i32 287454020, ptr addrspace(1) %p0 unordered, align 4
  store atomic i16 21862, ptr addrspace(1) %p2 unordered, align 2
  %v = load atomic i32, ptr addrspace(1) %p0 unordered, align 4
  ret i32 %v
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; Different allocation identities must not combine overlapping field spans.
; CHECK-LABEL: define i32 @different_arrays_merge(
; CHECK: invoke hotspotcc ptr addrspace(1) @jeandle.new_array
; CHECK: store atomic i16 21862, ptr addrspace(1) %p2 unordered, align 2
; CHECK: load atomic i32
define i32 @different_arrays_merge(i1 %choose) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  br i1 %choose, label %left, label %right
left:
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 12345 to ptr), i32 2, i32 24, i32 16, i32 1048576) to label %left_store unwind label %u
left_store:
  %p0 = getelementptr inbounds i8, ptr addrspace(1) %a, i64 16
  store atomic i32 287454020, ptr addrspace(1) %p0 unordered, align 4
  br label %merge
right:
  %b = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 12345 to ptr), i32 2, i32 24, i32 16, i32 1048576) to label %right_store unwind label %u
right_store:
  %p2 = getelementptr inbounds i8, ptr addrspace(1) %b, i64 18
  store atomic i16 21862, ptr addrspace(1) %p2 unordered, align 2
  br label %merge
merge:
  %arr = phi ptr addrspace(1) [ %a, %left_store ], [ %b, %right_store ]
  %p = getelementptr inbounds i8, ptr addrspace(1) %arr, i64 16
  %v = load atomic i32, ptr addrspace(1) %p unordered, align 4
  ret i32 %v
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; An element-sized store crossing two elements must also stay real.
; CHECK-LABEL: define i32 @cross_element_store(
; CHECK: invoke hotspotcc ptr addrspace(1) @jeandle.new_array
; CHECK: store atomic i32 287454020, ptr addrspace(1) %p2 unordered, align 2
; CHECK: load atomic i32
define i32 @cross_element_store() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %src = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 12345 to ptr), i32 2, i32 24, i32 16, i32 1048576) to label %init unwind label %u
init:
  %p0 = getelementptr inbounds i8, ptr addrspace(1) %src, i64 16
  %p2 = getelementptr inbounds i8, ptr addrspace(1) %src, i64 18
  store atomic i32 287454020, ptr addrspace(1) %p2 unordered, align 2
  %v = load atomic i32, ptr addrspace(1) %p0 unordered, align 4
  ret i32 %v
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; A wide group must fit in the array payload, including its final byte.
; CHECK-LABEL: define void @tail_group_store(
; CHECK: invoke hotspotcc ptr addrspace(1) @jeandle.new_array
; CHECK: store atomic i64 1, ptr addrspace(1) %p unordered, align 4
define void @tail_group_store() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %src = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 12345 to ptr), i32 2, i32 24, i32 16, i32 1048576) to label %init unwind label %u
init:
  %p = getelementptr inbounds i8, ptr addrspace(1) %src, i64 20
  store atomic i64 1, ptr addrspace(1) %p unordered, align 4
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; Complete wide groups still merge with default elements and remain virtual.
; CHECK-LABEL: define i64 @whole_group_merge(
; CHECK-NOT: @jeandle.new_array
; CHECK-NOT: store atomic
; CHECK: %[[WIDE:[^ ]+]] = phi i64
; CHECK: ret i64 %[[WIDE]]
define i64 @whole_group_merge(i1 %choose, i64 %value) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %src = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 12345 to ptr), i32 2, i32 24, i32 16, i32 1048576) to label %init unwind label %u
init:
  %p = getelementptr inbounds i8, ptr addrspace(1) %src, i64 16
  br i1 %choose, label %left, label %right
left:
  store atomic i64 %value, ptr addrspace(1) %p unordered, align 4
  br label %merge
right:
  br label %merge
merge:
  %v = load atomic i64, ptr addrspace(1) %p unordered, align 4
  ret i64 %v
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

attributes #0 = { "jeandle.copy.kind"="arraycopy" "jeandle.copy.validated" }
!java-method-compilation = !{}
