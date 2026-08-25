; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Iterative merge stabilization. Two outer virtual objects (allocated
; in entry, so both are virtual at every pred of the merge) each carry a field
; that references the SAME inner virtual on the left arm but disagree on the
; right arm. At the merge, the per-VO loop in mergeStates processes outer1
; first and triggers a nested materialize of `inner` at pred-A while
; synthesizing the field PHI. That materialize invalidates the per-pred
; ExitInfo for `inner` (now Materialized on pred-A) which any subsequent VO
; using `inner` would observe. The do-while in mergeStates discards the
; partial merge-BB CreatePHI effects from the first iteration and re-runs the
; per-VO loop; on the second iteration the materialize call short-circuits via
; MaterializedAtPred, no further Effects are emitted, and the loop converges.
;
; Expected optimization: both outers are fully scalar-replaced (no
; jeandle.new_instance for klass 67890). The single inner's original
; allocation is retained on the left arm. Each outer carries its own ptr
; addrspace(1) field PHI at the merge selecting between the inner OrigAlloc
; and the per-VO right-arm pointer.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @test_a5_two_outer_shared_inner(i1 %c,
                                            ptr addrspace(1) %p1,
                                            ptr addrspace(1) %p2)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %outer1 = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
               ptr inttoptr (i64 67890 to ptr), i32 16, i1 false)
            to label %n1 unwind label %u
n1:
  %outer2 = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
               ptr inttoptr (i64 67890 to ptr), i32 16, i1 false)
            to label %n unwind label %u
n:
  br i1 %c, label %left, label %right
left:
  %inner = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
              ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
           to label %lcont unwind label %u
lcont:
  %s1l = getelementptr inbounds i8, ptr addrspace(1) %outer1, i64 8
  store atomic ptr addrspace(1) %inner, ptr addrspace(1) %s1l unordered, align 8
  %s2l = getelementptr inbounds i8, ptr addrspace(1) %outer2, i64 8
  store atomic ptr addrspace(1) %inner, ptr addrspace(1) %s2l unordered, align 8
  br label %merge
right:
  %s1r = getelementptr inbounds i8, ptr addrspace(1) %outer1, i64 8
  store atomic ptr addrspace(1) %p1, ptr addrspace(1) %s1r unordered, align 8
  %s2r = getelementptr inbounds i8, ptr addrspace(1) %outer2, i64 8
  store atomic ptr addrspace(1) %p2, ptr addrspace(1) %s2r unordered, align 8
  br label %merge
merge:
  %sm1 = getelementptr inbounds i8, ptr addrspace(1) %outer1, i64 8
  %v1  = load atomic ptr addrspace(1), ptr addrspace(1) %sm1 unordered, align 8
  %sm2 = getelementptr inbounds i8, ptr addrspace(1) %outer2, i64 8
  %v2  = load atomic ptr addrspace(1), ptr addrspace(1) %sm2 unordered, align 8
  call void @sink(ptr addrspace(1) %v1)
  call void @sink(ptr addrspace(1) %v2)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @test_a5_two_outer_shared_inner
; Outers fully scalar-replaced (klass 67890 nowhere in the body).
; CHECK-NOT: i64 67890
; Inner has exactly one retained original allocation on the left arm.
; CHECK: invoke hotspotcc{{.*}}@jeandle.new_instance(ptr inttoptr (i64 12345 to ptr)
; Two distinct ptr addrspace(1) field PHIs at the merge.
; CHECK: = phi ptr addrspace(1)
; CHECK: = phi ptr addrspace(1)
; CHECK: call void @sink
; CHECK: call void @sink
; CHECK: ret void

!java-method-compilation = !{}
