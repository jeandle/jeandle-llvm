; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; PEA Case C — sub-slot load against a synthetic merged VO. The wide slot lives
; ONLY on the NON-pred-0 (right) arm; after the merge a sub-width i32 load reads
; offset 12, the high half of the i64 slot at offset 8 (within-slot offset 4).
;
;   left  (pred 0): stores i32 at offset 24    -> Fields {24}
;   right (pred 1): stores i64 at offset 8     -> Fields {8 (8 bytes)}
;
; Sub-slot / narrowing loads are intentionally UNSUPPORTED. The load bails to
; ineligible, which marks the synthetic VO and both per-pred source VOs
; ineligible: both objects materialize, the stores and the load survive, and
; the pointer PHI carries the two allocations. This is the conservative-but-
; sound outcome. (Regression guard: the merge must NOT crash on the bail.)

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @use(i32)
declare i32 @__gxx_personality_v0(...)

define void @test_casec_subslot_nonpred0(i1 %c)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  br i1 %c, label %left, label %right
left:
  %o1 = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 32, i1 false)
        to label %lstore unwind label %u
lstore:
  %l24 = getelementptr inbounds i8, ptr addrspace(1) %o1, i64 24
  store atomic i32 1, ptr addrspace(1) %l24 unordered, align 4
  br label %merge
right:
  %o2 = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 32, i1 false)
        to label %rstore unwind label %u
rstore:
  %r8 = getelementptr inbounds i8, ptr addrspace(1) %o2, i64 8
  store atomic i64 305419896, ptr addrspace(1) %r8 unordered, align 8
  br label %merge
merge:
  %p   = phi ptr addrspace(1) [ %o1, %lstore ], [ %o2, %rstore ]
  %s12 = getelementptr inbounds i8, ptr addrspace(1) %p, i64 12
  %v12 = load atomic i32, ptr addrspace(1) %s12 unordered, align 4
  call void @use(i32 %v12)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @test_casec_subslot_nonpred0
; Both objects materialize; sub-slot load is unsupported, so nothing folds.
; CHECK: invoke hotspotcc {{.*}}@jeandle.new_instance
; CHECK: invoke hotspotcc {{.*}}@jeandle.new_instance
; CHECK: phi ptr addrspace(1)
; CHECK: load atomic i32
; CHECK-NOT: pea.coerce
; CHECK: ret void

!java-method-compilation = !{}
