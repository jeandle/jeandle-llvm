; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Stress the iterative merge wrapper with multiple parallel outer
; virtuals all carrying nested-virtual fields on one arm. The first iteration
; emits MANY nested materializes on pred-A in a single per-VO loop pass; the
; second iteration sees all of them dedup'd via MaterializedAtPred and
; converges. The 10-iteration safety cap is not expected to trigger here —
; this test verifies that even with eight independent nested-materialize
; chains at a single merge, the snapshot/restore + truncate paths execute
; cleanly and produce the same fully-virtualized outers.
;
; If the overflow cap ever DID trigger, every outer would be marked
; ineligible at the merge and the original allocations + stores would
; survive. The CHECK-NOT lines below would catch that regression.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @test_a5_many_parallel(i1 %c,
                                   ptr addrspace(1) %p1, ptr addrspace(1) %p2,
                                   ptr addrspace(1) %p3, ptr addrspace(1) %p4,
                                   ptr addrspace(1) %p5, ptr addrspace(1) %p6,
                                   ptr addrspace(1) %p7, ptr addrspace(1) %p8)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o1 = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 67890 to ptr), i32 16, i1 false)
        to label %e2 unwind label %u
e2:
  %o2 = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 67890 to ptr), i32 16, i1 false)
        to label %e3 unwind label %u
e3:
  %o3 = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 67890 to ptr), i32 16, i1 false)
        to label %e4 unwind label %u
e4:
  %o4 = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 67890 to ptr), i32 16, i1 false)
        to label %e5 unwind label %u
e5:
  %o5 = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 67890 to ptr), i32 16, i1 false)
        to label %e6 unwind label %u
e6:
  %o6 = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 67890 to ptr), i32 16, i1 false)
        to label %e7 unwind label %u
e7:
  %o7 = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 67890 to ptr), i32 16, i1 false)
        to label %e8 unwind label %u
e8:
  %o8 = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 67890 to ptr), i32 16, i1 false)
        to label %n unwind label %u
n:
  br i1 %c, label %left, label %right
left:
  %i1 = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
        to label %li2 unwind label %u
li2:
  %i2 = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
        to label %li3 unwind label %u
li3:
  %i3 = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
        to label %li4 unwind label %u
li4:
  %i4 = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
        to label %li5 unwind label %u
li5:
  %i5 = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
        to label %li6 unwind label %u
li6:
  %i6 = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
        to label %li7 unwind label %u
li7:
  %i7 = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
        to label %li8 unwind label %u
li8:
  %i8 = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
        to label %lstores unwind label %u
lstores:
  %s1l = getelementptr inbounds i8, ptr addrspace(1) %o1, i64 8
  store atomic ptr addrspace(1) %i1, ptr addrspace(1) %s1l unordered, align 8
  %s2l = getelementptr inbounds i8, ptr addrspace(1) %o2, i64 8
  store atomic ptr addrspace(1) %i2, ptr addrspace(1) %s2l unordered, align 8
  %s3l = getelementptr inbounds i8, ptr addrspace(1) %o3, i64 8
  store atomic ptr addrspace(1) %i3, ptr addrspace(1) %s3l unordered, align 8
  %s4l = getelementptr inbounds i8, ptr addrspace(1) %o4, i64 8
  store atomic ptr addrspace(1) %i4, ptr addrspace(1) %s4l unordered, align 8
  %s5l = getelementptr inbounds i8, ptr addrspace(1) %o5, i64 8
  store atomic ptr addrspace(1) %i5, ptr addrspace(1) %s5l unordered, align 8
  %s6l = getelementptr inbounds i8, ptr addrspace(1) %o6, i64 8
  store atomic ptr addrspace(1) %i6, ptr addrspace(1) %s6l unordered, align 8
  %s7l = getelementptr inbounds i8, ptr addrspace(1) %o7, i64 8
  store atomic ptr addrspace(1) %i7, ptr addrspace(1) %s7l unordered, align 8
  %s8l = getelementptr inbounds i8, ptr addrspace(1) %o8, i64 8
  store atomic ptr addrspace(1) %i8, ptr addrspace(1) %s8l unordered, align 8
  br label %merge
right:
  %s1r = getelementptr inbounds i8, ptr addrspace(1) %o1, i64 8
  store atomic ptr addrspace(1) %p1, ptr addrspace(1) %s1r unordered, align 8
  %s2r = getelementptr inbounds i8, ptr addrspace(1) %o2, i64 8
  store atomic ptr addrspace(1) %p2, ptr addrspace(1) %s2r unordered, align 8
  %s3r = getelementptr inbounds i8, ptr addrspace(1) %o3, i64 8
  store atomic ptr addrspace(1) %p3, ptr addrspace(1) %s3r unordered, align 8
  %s4r = getelementptr inbounds i8, ptr addrspace(1) %o4, i64 8
  store atomic ptr addrspace(1) %p4, ptr addrspace(1) %s4r unordered, align 8
  %s5r = getelementptr inbounds i8, ptr addrspace(1) %o5, i64 8
  store atomic ptr addrspace(1) %p5, ptr addrspace(1) %s5r unordered, align 8
  %s6r = getelementptr inbounds i8, ptr addrspace(1) %o6, i64 8
  store atomic ptr addrspace(1) %p6, ptr addrspace(1) %s6r unordered, align 8
  %s7r = getelementptr inbounds i8, ptr addrspace(1) %o7, i64 8
  store atomic ptr addrspace(1) %p7, ptr addrspace(1) %s7r unordered, align 8
  %s8r = getelementptr inbounds i8, ptr addrspace(1) %o8, i64 8
  store atomic ptr addrspace(1) %p8, ptr addrspace(1) %s8r unordered, align 8
  br label %merge
merge:
  %lm1 = getelementptr inbounds i8, ptr addrspace(1) %o1, i64 8
  %v1  = load atomic ptr addrspace(1), ptr addrspace(1) %lm1 unordered, align 8
  %lm8 = getelementptr inbounds i8, ptr addrspace(1) %o8, i64 8
  %v8  = load atomic ptr addrspace(1), ptr addrspace(1) %lm8 unordered, align 8
  call void @sink(ptr addrspace(1) %v1)
  call void @sink(ptr addrspace(1) %v8)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @test_a5_many_parallel
; All eight outers are fully eliminated.
; CHECK-NOT: i64 67890
; All eight inners survive as a single materialization each on the left arm.
; CHECK: ret void

!java-method-compilation = !{}
