; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; PEA Case C — THREE predecessors (switch) each allocate the same Klass and
; store DIFFERENT field offsets: arm0 -> {8}, arm1 -> {16}, arm2 -> {24}.
; The synthetic merged VO's Fields must be the union {8, 16, 24} across all
; three preds (not just pred 0). Each post-merge load folds to a 3-input PHI
; with the known value on its owning arm and default 0 on the other two arms.
; All three allocations are eliminated.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @use(i32)
declare i32 @__gxx_personality_v0(...)

define void @test_casec_three_preds(i32 %sel)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  switch i32 %sel, label %a0 [ i32 1, label %a1
                               i32 2, label %a2 ]
a0:
  %o0 = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 32, i1 false)
        to label %a0s unwind label %u
a0s:
  %p0 = getelementptr inbounds i8, ptr addrspace(1) %o0, i64 8
  store atomic i32 100, ptr addrspace(1) %p0 unordered, align 4
  br label %merge
a1:
  %o1 = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 32, i1 false)
        to label %a1s unwind label %u
a1s:
  %p1 = getelementptr inbounds i8, ptr addrspace(1) %o1, i64 16
  store atomic i32 200, ptr addrspace(1) %p1 unordered, align 4
  br label %merge
a2:
  %o2 = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 32, i1 false)
        to label %a2s unwind label %u
a2s:
  %p2 = getelementptr inbounds i8, ptr addrspace(1) %o2, i64 24
  store atomic i32 300, ptr addrspace(1) %p2 unordered, align 4
  br label %merge
merge:
  %p   = phi ptr addrspace(1) [ %o0, %a0s ], [ %o1, %a1s ], [ %o2, %a2s ]
  %s8  = getelementptr inbounds i8, ptr addrspace(1) %p, i64 8
  %v8  = load atomic i32, ptr addrspace(1) %s8 unordered, align 4
  %s16 = getelementptr inbounds i8, ptr addrspace(1) %p, i64 16
  %v16 = load atomic i32, ptr addrspace(1) %s16 unordered, align 4
  %s24 = getelementptr inbounds i8, ptr addrspace(1) %p, i64 24
  %v24 = load atomic i32, ptr addrspace(1) %s24 unordered, align 4
  call void @use(i32 %v8)
  call void @use(i32 %v16)
  call void @use(i32 %v24)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @test_casec_three_preds
; CHECK-NOT: jeandle.new_instance
; CHECK-NOT: store atomic
; CHECK-NOT: load atomic
; CHECK-DAG: phi i32 [ 100, %{{.*}} ], [ 0, %{{.*}} ], [ 0, %{{.*}} ]
; CHECK-DAG: phi i32 [ 0, %{{.*}} ], [ 200, %{{.*}} ], [ 0, %{{.*}} ]
; CHECK-DAG: phi i32 [ 0, %{{.*}} ], [ 0, %{{.*}} ], [ 300, %{{.*}} ]
; CHECK: ret void

!java-method-compilation = !{}
