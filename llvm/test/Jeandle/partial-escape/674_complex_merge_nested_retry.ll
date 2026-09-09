; RUN: opt -S -verify-each -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s
; RUN: opt -S -verify-each -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s --check-prefix=STORECOUNT
; RUN: opt -S -verify-each -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s --check-prefix=NEGATIVE

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink_i32(i32)
declare void @sink_i64(i64)
declare void @sink_ref(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

; An i32 and a float at the same offset cannot form one typed field PHI.
; An incompatible merge materializes the object on both predecessors and
; preserves both stores plus the real load.
define void @merge_i32_float(i1 %c)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
           ptr inttoptr (i64 67401 to ptr), i32 32, i1 false)
       to label %dispatch unwind label %unwind
dispatch:
  br i1 %c, label %left, label %right
left:
  %lf = getelementptr inbounds i8, ptr addrspace(1) %o, i64 16
  store atomic i32 7, ptr addrspace(1) %lf unordered, align 4
  br label %merge
right:
  %rf = getelementptr inbounds i8, ptr addrspace(1) %o, i64 16
  store atomic float 1.500000e+00, ptr addrspace(1) %rf unordered, align 4
  br label %merge
merge:
  %mf = getelementptr inbounds i8, ptr addrspace(1) %o, i64 16
  %v = load atomic i32, ptr addrspace(1) %mf unordered, align 4
  call void @sink_i32(i32 %v)
  ret void
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @merge_i32_float
; CHECK: %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK: left:
; CHECK-NEXT: [[I32_SLOT:%[A-Za-z0-9._]+]] = getelementptr inbounds i8, ptr addrspace(1) %o, i64 16
; CHECK-NEXT: store atomic i32 7, ptr addrspace(1) [[I32_SLOT]] unordered, align 4
; CHECK-NEXT: br label %merge
; CHECK: right:
; CHECK-NEXT: [[FLOAT_SLOT:%[A-Za-z0-9._]+]] = getelementptr inbounds i8, ptr addrspace(1) %o, i64 16
; CHECK-NEXT: store atomic float 1.500000e+00, ptr addrspace(1) [[FLOAT_SLOT]] unordered, align 4
; CHECK-NEXT: br label %merge
; CHECK: %v = load atomic i32, ptr addrspace(1) %mf unordered, align 4
; CHECK: call void @sink_i32(i32 %v)
; CHECK-NOT: pea.field.phi
; CHECK-NOT: poison

; A primitive and a Java reference at one offset are different Java slot
; kinds even though they have the same machine width.  The whole object is
; materialized on both predecessors.
define void @merge_scalar_reference(i1 %c, ptr addrspace(1) %ref)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  br i1 %c, label %left_alloc, label %right_alloc
left_alloc:
  %left_o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
                ptr inttoptr (i64 67402 to ptr), i32 32, i1 false)
            to label %left unwind label %unwind
left:
  %lf = getelementptr inbounds i8, ptr addrspace(1) %left_o, i64 16
  store atomic i64 9, ptr addrspace(1) %lf unordered, align 8
  br label %merge
right_alloc:
  %right_o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
                 ptr inttoptr (i64 67402 to ptr), i32 32, i1 false)
             to label %right unwind label %unwind
right:
  %rf = getelementptr inbounds i8, ptr addrspace(1) %right_o, i64 16
  store atomic ptr addrspace(1) %ref, ptr addrspace(1) %rf unordered, align 8
  br label %merge
merge:
  %o = phi ptr addrspace(1) [ %left_o, %left ], [ %right_o, %right ]
  %mf = getelementptr inbounds i8, ptr addrspace(1) %o, i64 16
  %v = load atomic i64, ptr addrspace(1) %mf unordered, align 8
  call void @sink_i64(i64 %v)
  ret void
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @merge_scalar_reference
; CHECK: %left_o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK: left:
; CHECK-NEXT: [[I64_SLOT:%[A-Za-z0-9._]+]] = getelementptr inbounds i8, ptr addrspace(1) %left_o, i64 16
; CHECK-NEXT: store atomic i64 9, ptr addrspace(1) [[I64_SLOT]] unordered, align 8
; CHECK-NEXT: br label %merge
; CHECK: %right_o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK: right:
; CHECK-NEXT: [[REF_SLOT:%[A-Za-z0-9._]+]] = getelementptr inbounds i8, ptr addrspace(1) %right_o, i64 16
; CHECK-NEXT: store atomic ptr addrspace(1) %ref, ptr addrspace(1) [[REF_SLOT]] unordered, align 8
; CHECK-NEXT: br label %merge
; CHECK: %o = phi ptr addrspace(1) [ %left_o, %left ], [ %right_o, %right ]
; CHECK: %v = load atomic i64, ptr addrspace(1) %mf unordered, align 8
; CHECK: call void @sink_i64(i64 %v)
; CHECK-NOT: pea.field.phi
; CHECK-NOT: poison

; The child is already materialized on the left but virtual on the right.
; Merging the outer reference field materializes the right-side child.  Both
; inputs then name the same retained allocation, so no redundant PHI remains.
define void @merge_virtual_materialized_child(i1 %c)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %outer = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
               ptr inttoptr (i64 67403 to ptr), i32 32, i1 false)
           to label %new_child unwind label %unwind
new_child:
  %child = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
               ptr inttoptr (i64 67404 to ptr), i32 32, i1 false)
           to label %init unwind label %unwind
init:
  %child_field = getelementptr inbounds i8, ptr addrspace(1) %child, i64 16
  store atomic i32 31, ptr addrspace(1) %child_field unordered, align 4
  %outer_field = getelementptr inbounds i8, ptr addrspace(1) %outer, i64 16
  store atomic ptr addrspace(1) %child, ptr addrspace(1) %outer_field unordered, align 8
  br i1 %c, label %left, label %right
left:
  call void @sink_ref(ptr addrspace(1) %child)
  br label %merge
right:
  br label %merge
merge:
  %mf = getelementptr inbounds i8, ptr addrspace(1) %outer, i64 16
  %selected = load atomic ptr addrspace(1), ptr addrspace(1) %mf unordered, align 8
  call void @sink_ref(ptr addrspace(1) %selected)
  ret void
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @merge_virtual_materialized_child
; CHECK-COUNT-1: invoke hotspotcc ptr addrspace(1) @jeandle.new_instance{{.*}}i64 67404
; CHECK: left:
; CHECK-NEXT: [[LEFT_CHILD_SLOT:%pea.matslot[0-9]*]] = getelementptr inbounds i8, ptr addrspace(1) %child, i64 16
; CHECK-NEXT: store atomic i32 31, ptr addrspace(1) [[LEFT_CHILD_SLOT]] unordered, align 4
; CHECK-NEXT: call void @sink_ref(ptr addrspace(1) %child)
; CHECK-NEXT: br label %merge
; CHECK: right:
; CHECK-NEXT: [[RIGHT_CHILD_SLOT:%pea.matslot[0-9]*]] = getelementptr inbounds i8, ptr addrspace(1) %child, i64 16
; CHECK-NEXT: store atomic i32 31, ptr addrspace(1) [[RIGHT_CHILD_SLOT]] unordered, align 4
; CHECK-NEXT: br label %merge
; CHECK-NOT: pea.field.phi
; CHECK: merge:
; CHECK-NEXT: call void @sink_ref(ptr addrspace(1) %child)
; CHECK-NEXT: ret void
; CHECK-NOT: poison

; Materializing the shared inner while merging outer1 changes the predecessor
; snapshot used by outer2.  The merge fixpoint must retry, preserve one replay
; per predecessor for the inner, and create two complete field PHIs without
; duplicate inputs.
define void @merge_inner_changes_outer_retry(i1 %c, ptr addrspace(1) %p1,
                                              ptr addrspace(1) %p2)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %outer1 = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
                ptr inttoptr (i64 67405 to ptr), i32 32, i1 false)
            to label %new_outer2 unwind label %unwind
new_outer2:
  %outer2 = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
                ptr inttoptr (i64 67405 to ptr), i32 32, i1 false)
            to label %new_inner unwind label %unwind
new_inner:
  %inner = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
               ptr inttoptr (i64 67406 to ptr), i32 32, i1 false)
           to label %init unwind label %unwind
init:
  %inner_field = getelementptr inbounds i8, ptr addrspace(1) %inner, i64 16
  store atomic i32 47, ptr addrspace(1) %inner_field unordered, align 4
  br i1 %c, label %left, label %right
left:
  %o1l = getelementptr inbounds i8, ptr addrspace(1) %outer1, i64 16
  store atomic ptr addrspace(1) %inner, ptr addrspace(1) %o1l unordered, align 8
  %o2l = getelementptr inbounds i8, ptr addrspace(1) %outer2, i64 16
  store atomic ptr addrspace(1) %inner, ptr addrspace(1) %o2l unordered, align 8
  br label %merge
right:
  %o1r = getelementptr inbounds i8, ptr addrspace(1) %outer1, i64 16
  store atomic ptr addrspace(1) %p1, ptr addrspace(1) %o1r unordered, align 8
  %o2r = getelementptr inbounds i8, ptr addrspace(1) %outer2, i64 16
  store atomic ptr addrspace(1) %p2, ptr addrspace(1) %o2r unordered, align 8
  br label %merge
merge:
  %m1 = getelementptr inbounds i8, ptr addrspace(1) %outer1, i64 16
  %v1 = load atomic ptr addrspace(1), ptr addrspace(1) %m1 unordered, align 8
  %m2 = getelementptr inbounds i8, ptr addrspace(1) %outer2, i64 16
  %v2 = load atomic ptr addrspace(1), ptr addrspace(1) %m2 unordered, align 8
  call void @sink_ref(ptr addrspace(1) %v1)
  call void @sink_ref(ptr addrspace(1) %v2)
  ret void
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @merge_inner_changes_outer_retry
; CHECK-NOT: i64 67405
; CHECK-COUNT-1: invoke hotspotcc ptr addrspace(1) @jeandle.new_instance{{.*}}i64 67406
; CHECK: left:
; CHECK-NEXT: [[LEFT_INNER_SLOT:%pea.matslot[0-9]*]] = getelementptr inbounds i8, ptr addrspace(1) %inner, i64 16
; CHECK-NEXT: store atomic i32 47, ptr addrspace(1) [[LEFT_INNER_SLOT]] unordered, align 4
; CHECK-NEXT: br label %merge
; CHECK: right:
; CHECK-NEXT: [[RIGHT_INNER_SLOT:%pea.matslot[0-9]*]] = getelementptr inbounds i8, ptr addrspace(1) %inner, i64 16
; CHECK-NEXT: store atomic i32 47, ptr addrspace(1) [[RIGHT_INNER_SLOT]] unordered, align 4
; CHECK-NEXT: br label %merge
; CHECK: merge:
; CHECK-NEXT: [[OUTER1:%pea.field.phi[^ ]*]] = phi ptr addrspace(1) [ %p1, %right ], [ %inner, %left ]
; CHECK-NEXT: [[OUTER2:%pea.field.phi[^ ]*]] = phi ptr addrspace(1) [ %p2, %right ], [ %inner, %left ]
; CHECK-NEXT: call void @sink_ref(ptr addrspace(1) [[OUTER1]])
; CHECK-NEXT: call void @sink_ref(ptr addrspace(1) [[OUTER2]])
; CHECK-NEXT: ret void
; CHECK-NOT: poison

; STORECOUNT-LABEL: define void @merge_i32_float
; STORECOUNT-COUNT-2: store atomic
; STORECOUNT-NOT: store atomic
; STORECOUNT-LABEL: define void @merge_scalar_reference
; STORECOUNT-COUNT-2: store atomic
; STORECOUNT-NOT: store atomic
; STORECOUNT-LABEL: define void @merge_virtual_materialized_child
; STORECOUNT-COUNT-2: store atomic
; STORECOUNT-NOT: store atomic
; STORECOUNT-LABEL: define void @merge_inner_changes_outer_retry
; STORECOUNT-COUNT-2: store atomic
; STORECOUNT-NOT: store atomic

; NEGATIVE-LABEL: define void @merge_i32_float
; NEGATIVE-NOT: pea.field.phi
; NEGATIVE-NOT: poison
; NEGATIVE-LABEL: define void @merge_scalar_reference
; NEGATIVE-NOT: pea.field.phi
; NEGATIVE-NOT: poison
; NEGATIVE-LABEL: define void @merge_virtual_materialized_child
; NEGATIVE-NOT: pea.field.phi
; NEGATIVE-NOT: poison
; NEGATIVE-LABEL: define void @merge_inner_changes_outer_retry
; NEGATIVE-NOT: poison

!java-method-compilation = !{}
