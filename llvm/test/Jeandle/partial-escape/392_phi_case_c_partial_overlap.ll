; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; PEA Case C — both arms allocate the SAME Klass and store MULTIPLE fields with
; a PARTIAL overlap of offsets: left writes {8, 16}, right writes {16, 24}.
; The synthetic VO's Fields must be the union {8, 16, 24}.
;   * offset 8  : known left, default 0 right  -> phi {11, 0}
;   * offset 16 : known on both                -> phi {22, 99}
;   * offset 24 : default 0 left, known right   -> phi {0, 44}
; Every post-merge load folds through a per-entry PHI; both allocs eliminated.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @use(i32)
declare i32 @__gxx_personality_v0(...)

define void @test_casec_partial_overlap(i1 %c)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  br i1 %c, label %left, label %right
left:
  %o1 = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 32, i1 false)
        to label %lstore unwind label %u
lstore:
  %l8 = getelementptr inbounds i8, ptr addrspace(1) %o1, i64 8
  store atomic i32 11, ptr addrspace(1) %l8 unordered, align 4
  %l16 = getelementptr inbounds i8, ptr addrspace(1) %o1, i64 16
  store atomic i32 22, ptr addrspace(1) %l16 unordered, align 4
  br label %merge
right:
  %o2 = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 32, i1 false)
        to label %rstore unwind label %u
rstore:
  %r16 = getelementptr inbounds i8, ptr addrspace(1) %o2, i64 16
  store atomic i32 99, ptr addrspace(1) %r16 unordered, align 4
  %r24 = getelementptr inbounds i8, ptr addrspace(1) %o2, i64 24
  store atomic i32 44, ptr addrspace(1) %r24 unordered, align 4
  br label %merge
merge:
  %p  = phi ptr addrspace(1) [ %o1, %lstore ], [ %o2, %rstore ]
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

; CHECK-LABEL: define void @test_casec_partial_overlap
; CHECK-NOT: jeandle.new_instance
; CHECK-NOT: store atomic
; CHECK-NOT: load atomic
; CHECK-DAG: phi i32 [ 11, %{{.*}} ], [ 0, %{{.*}} ]
; CHECK-DAG: phi i32 [ 22, %{{.*}} ], [ 99, %{{.*}} ]
; CHECK-DAG: phi i32 [ 0, %{{.*}} ], [ 44, %{{.*}} ]
; CHECK: ret void

!java-method-compilation = !{}
