; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Constant-fold fast path must survive snapshot/restore. The merge
; has two virtual outer objects: outer1 has the SAME constant i32 stored at
; offset 8 on both preds (constant agreement -> no field PHI needed); outer2
; has a VirtualRef(inner) on the left arm and a different pointer on the
; right arm (forces field-PHI synthesis with a nested materialize, which
; triggers the merge retry). After the retry converges, outer1's field is still
; the constant 42 (NOT a PHI), and the post-merge load through outer1
; folds to the constant.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(ptr addrspace(1))
declare void @sinki(i32)
declare i32 @__gxx_personality_v0(...)

define void @test_a5_constant_fast_path(i1 %c, ptr addrspace(1) %p)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %outer1 = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
               ptr inttoptr (i64 67890 to ptr), i32 16, i1 false)
            to label %e2 unwind label %u
e2:
  %outer2 = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
               ptr inttoptr (i64 67891 to ptr), i32 16, i1 false)
            to label %n unwind label %u
n:
  br i1 %c, label %left, label %right
left:
  %inner = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
              ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
           to label %lst unwind label %u
lst:
  %s1l = getelementptr inbounds i8, ptr addrspace(1) %outer1, i64 8
  store atomic i32 42, ptr addrspace(1) %s1l unordered, align 4
  %s2l = getelementptr inbounds i8, ptr addrspace(1) %outer2, i64 8
  store atomic ptr addrspace(1) %inner, ptr addrspace(1) %s2l unordered, align 8
  br label %merge
right:
  %s1r = getelementptr inbounds i8, ptr addrspace(1) %outer1, i64 8
  store atomic i32 42, ptr addrspace(1) %s1r unordered, align 4
  %s2r = getelementptr inbounds i8, ptr addrspace(1) %outer2, i64 8
  store atomic ptr addrspace(1) %p, ptr addrspace(1) %s2r unordered, align 8
  br label %merge
merge:
  %sm1 = getelementptr inbounds i8, ptr addrspace(1) %outer1, i64 8
  %v1  = load atomic i32, ptr addrspace(1) %sm1 unordered, align 4
  %sm2 = getelementptr inbounds i8, ptr addrspace(1) %outer2, i64 8
  %v2  = load atomic ptr addrspace(1), ptr addrspace(1) %sm2 unordered, align 8
  call void @sinki(i32 %v1)
  call void @sink(ptr addrspace(1) %v2)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @test_a5_constant_fast_path
; Both outers fully scalar-replaced.
; CHECK-NOT: i64 67890
; CHECK-NOT: i64 67891
; Inner materialized once on the left arm (needed for outer2's field PHI).
; CHECK: invoke hotspotcc{{.*}}@jeandle.new_instance(ptr inttoptr (i64 12345 to ptr)
; outer2.field reads through a ptr addrspace(1) PHI of (inner-materialized, %p).
; The PHI is emitted at the head of the merge block, ahead of the loads/sinks.
; CHECK: = phi ptr addrspace(1)
; Constant-fold fast path: outer1.field reads 42 directly (no i32 PHI).
; CHECK-NOT: phi i32
; CHECK: call void @sinki(i32 42)
; CHECK: call void @sink(ptr addrspace(1)
; CHECK: ret void

!java-method-compilation = !{}
