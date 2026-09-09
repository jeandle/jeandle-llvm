; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; PEA Case C — both arms allocate the SAME Klass, but the LEFT arm (which is
; PHI-incoming index 0, i.e. the Ref/duplicate() source) stores NOTHING while
; the right arm stores offset 8. The left VO's Fields is therefore empty.
;
; The differing stored-field counts (0 vs 1) do not block the merge: the
; synthetic VO's Fields = union {8} (seeded by the right arm even though
; duplicate() copied the empty left Fields). Offset 8 is default 0 on the
; left arm and 5 on the right, folding to a phi {0, 5}. Both allocations
; are eliminated.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @use(i32)
declare i32 @__gxx_personality_v0(...)

define void @test_casec_one_branch_empty(i1 %c)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  br i1 %c, label %left, label %right
left:
  %o1 = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
        to label %lcont unwind label %u
lcont:
  br label %merge
right:
  %o2 = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
        to label %rstore unwind label %u
rstore:
  %sr = getelementptr inbounds i8, ptr addrspace(1) %o2, i64 8
  store atomic i32 5, ptr addrspace(1) %sr unordered, align 4
  br label %merge
merge:
  %p  = phi ptr addrspace(1) [ %o1, %lcont ], [ %o2, %rstore ]
  %sm = getelementptr inbounds i8, ptr addrspace(1) %p, i64 8
  %v  = load atomic i32, ptr addrspace(1) %sm unordered, align 4
  call void @use(i32 %v)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @test_casec_one_branch_empty
; CHECK-NOT: jeandle.new_instance
; CHECK-NOT: store atomic
; CHECK-NOT: load atomic
; CHECK: phi i32 [ 0, %{{.*}} ], [ 5, %{{.*}} ]
; CHECK: ret void

!java-method-compilation = !{}
