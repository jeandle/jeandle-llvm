; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; PEA Case C — diamond CFG, both arms allocate the SAME Klass but store to
; DIFFERENT field offsets (left writes offset 8, right writes offset 16).
;
; Each per-pred VO ends with Fields.size() == 1 but for DIFFERENT offsets, so
; a field-count comparison alone conveys nothing — the synthetic VO's Fields
; must be the UNION {8, 16}. After the merge, both fields are read back:
; offset 8 is known only on the left path (default 0 on the right) and offset
; 16 only on the right (default 0 on the left), so each folds to a per-entry
; PHI of {value, 0}. Both allocations are eliminated.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @use(i32)
declare i32 @__gxx_personality_v0(...)

define void @test_casec_divergent_offsets(i1 %c)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  br i1 %c, label %left, label %right
left:
  %o1 = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 24, i1 false)
        to label %lstore unwind label %u
lstore:
  %sl = getelementptr inbounds i8, ptr addrspace(1) %o1, i64 8
  store atomic i32 7, ptr addrspace(1) %sl unordered, align 4
  br label %merge
right:
  %o2 = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 24, i1 false)
        to label %rstore unwind label %u
rstore:
  %sr = getelementptr inbounds i8, ptr addrspace(1) %o2, i64 16
  store atomic i32 13, ptr addrspace(1) %sr unordered, align 4
  br label %merge
merge:
  %p  = phi ptr addrspace(1) [ %o1, %lstore ], [ %o2, %rstore ]
  %s8 = getelementptr inbounds i8, ptr addrspace(1) %p, i64 8
  %v8 = load atomic i32, ptr addrspace(1) %s8 unordered, align 4
  %s16 = getelementptr inbounds i8, ptr addrspace(1) %p, i64 16
  %v16 = load atomic i32, ptr addrspace(1) %s16 unordered, align 4
  call void @use(i32 %v8)
  call void @use(i32 %v16)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @test_casec_divergent_offsets
; CHECK-NOT: jeandle.new_instance
; CHECK-NOT: store atomic
; CHECK-NOT: load atomic
; Offset 8 known on the left arm, default 0 on the right.
; CHECK-DAG: phi i32 [ 7, %{{.*}} ], [ 0, %{{.*}} ]
; Offset 16 known on the right arm, default 0 on the left.
; CHECK-DAG: phi i32 [ 0, %{{.*}} ], [ 13, %{{.*}} ]
; CHECK: ret void

!java-method-compilation = !{}
