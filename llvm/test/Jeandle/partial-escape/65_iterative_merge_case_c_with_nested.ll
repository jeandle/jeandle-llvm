; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Verify that the snapshot/restore in mergeStates does not perturb
; the downstream Case C synthesis path in processBlockPhis when Case C itself
; triggers nested materializes. Both arms allocate `outer-klass` AND
; `inner-klass`, storing the local inner into the local outer's field; the
; explicit PHI at the merge gives Case C two distinct virtual ObjectIDs of
; compatible shape. Case C's per-field synthesis sees VirtualRef(inner_a) on
; pred-A and VirtualRef(inner_b) on pred-B, materializes inner_a at left and
; inner_b at right, and builds a field PHI selecting between them.
;
; The do-while wrapper around mergeStates must be a no-op on inputs where
; mergeStates has no virtual to process (here, no outers are tracked at
; merge entry because both o1 and o2 are allocated INSIDE their respective
; arms), so Case C runs identically regardless of the wrapper.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @test_a5_case_c_nested(i1 %c)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  br i1 %c, label %left, label %right
left:
  %o1 = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 67890 to ptr), i32 16, i1 false)
        to label %lin unwind label %u
lin:
  %ia = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
        to label %lstore unwind label %u
lstore:
  %sl = getelementptr inbounds i8, ptr addrspace(1) %o1, i64 8
  store atomic ptr addrspace(1) %ia, ptr addrspace(1) %sl unordered, align 8
  br label %merge
right:
  %o2 = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 67890 to ptr), i32 16, i1 false)
        to label %rin unwind label %u
rin:
  %ib = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
        to label %rstore unwind label %u
rstore:
  %sr = getelementptr inbounds i8, ptr addrspace(1) %o2, i64 8
  store atomic ptr addrspace(1) %ib, ptr addrspace(1) %sr unordered, align 8
  br label %merge
merge:
  %p  = phi ptr addrspace(1) [ %o1, %lstore ], [ %o2, %rstore ]
  %sm = getelementptr inbounds i8, ptr addrspace(1) %p, i64 8
  %v  = load atomic ptr addrspace(1), ptr addrspace(1) %sm unordered, align 8
  call void @sink(ptr addrspace(1) %v)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @test_a5_case_c_nested
; Outer klass (67890) entirely scalar-replaced.
; CHECK-NOT: i64 67890
; Inner klass (12345) materialized exactly twice (one per pred).
; CHECK: invoke hotspotcc{{.*}}@jeandle.new_instance(ptr inttoptr (i64 12345 to ptr)
; CHECK: invoke hotspotcc{{.*}}@jeandle.new_instance(ptr inttoptr (i64 12345 to ptr)
; Case C synthesized field PHI selects between the two inner materializations.
; CHECK: = phi ptr addrspace(1)
; CHECK: call void @sink
; CHECK: ret void

!java-method-compilation = !{}
