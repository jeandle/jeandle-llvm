; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Three-deep nested-virtual chain at a diamond merge. outer is
; allocated in entry (virtual on both preds at the merge); on the left arm
; outer.field = middle and middle.field = inner (both also virtual); on the
; right arm outer.field = an unrelated incoming pointer. mergeStates' per-VO
; field-PHI synthesis for outer triggers a nested materialize of `middle` at
; pred-left, which in turn (via materializeAtPredFromExitInfo's recursive
; "materialize inner first" path) materializes `inner` at pred-left too.
; Two distinct (Pred, ID) materializations are emitted in a single per-VO
; loop iteration; the do-while wrapper detects Changed and re-runs the loop,
; which converges (no new materializes) on the second pass.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @test_a5_three_chain(i1 %c, ptr addrspace(1) %p)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %outer = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
              ptr inttoptr (i64 67890 to ptr), i32 16, i1 false)
           to label %n unwind label %u
n:
  br i1 %c, label %left, label %right
left:
  %middle = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
               ptr inttoptr (i64 23456 to ptr), i32 16, i1 false)
            to label %lin unwind label %u
lin:
  %inner = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
              ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
           to label %lst unwind label %u
lst:
  %ms = getelementptr inbounds i8, ptr addrspace(1) %middle, i64 8
  store atomic ptr addrspace(1) %inner, ptr addrspace(1) %ms unordered, align 8
  %os = getelementptr inbounds i8, ptr addrspace(1) %outer, i64 8
  store atomic ptr addrspace(1) %middle, ptr addrspace(1) %os unordered, align 8
  br label %merge
right:
  %or = getelementptr inbounds i8, ptr addrspace(1) %outer, i64 8
  store atomic ptr addrspace(1) %p, ptr addrspace(1) %or unordered, align 8
  br label %merge
merge:
  %om = getelementptr inbounds i8, ptr addrspace(1) %outer, i64 8
  %v  = load atomic ptr addrspace(1), ptr addrspace(1) %om unordered, align 8
  call void @sink(ptr addrspace(1) %v)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @test_a5_three_chain
; Outer is fully scalar-replaced.
; CHECK-NOT: i64 67890
; Middle and inner each materialize exactly once on the left arm.
; CHECK-DAG: invoke hotspotcc{{.*}}@jeandle.new_instance(ptr inttoptr (i64 23456 to ptr)
; CHECK-DAG: invoke hotspotcc{{.*}}@jeandle.new_instance(ptr inttoptr (i64 12345 to ptr)
; Field PHI for outer.field selects between the materialized middle and %p.
; CHECK: = phi ptr addrspace(1)
; CHECK: call void @sink
; CHECK: ret void

!java-method-compilation = !{}
