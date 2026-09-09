; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s
; RUN: opt -disable-output -passes="require<partial-escape-analysis>" \
; RUN:     -jeandle-trace-pea \
; RUN:     -jeandle-pea-analyze-function=test_field_phi_sparse_offsets \
; RUN:     %s 2>&1 | FileCheck %s --check-prefix=TRACE

; MergeProcessor / mergeFieldStates per-offset field PHI with SPARSE offsets.
;
; Same virtual object on both arms, but each arm writes a DIFFERENT offset:
;   left  stores offset 8  = 10
;   right stores offset 16 = 40
; At the merge, offset 8 is non-default only on the left (default 0 on
; right) and offset 16 is non-default only on the right (default 0 on left).
; Both offsets therefore disagree across preds. mergeFieldStates takes the
; UNION of tracked offsets and synthesizes an independent i32 field PHI per
; offset. The post-merge loads fold through the two PHIs.
;
; This pins the per-offset union + shallowEquals-carry + per-offset PHI
; synthesis path of mergeFieldStates for the same-VO (non-Case-C) case;
; existing offset-disagreement tests (391/392/398) are all Case-C.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @use(i32)
declare i32 @__gxx_personality_v0(...)

define void @test_field_phi_sparse_offsets(i1 %c) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 32, i1 false)
       to label %n unwind label %u
n:
  br i1 %c, label %left, label %right
left:
  %s8 = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  store atomic i32 10, ptr addrspace(1) %s8 unordered, align 4
  br label %merge
right:
  %s16 = getelementptr inbounds i8, ptr addrspace(1) %o, i64 16
  store atomic i32 40, ptr addrspace(1) %s16 unordered, align 4
  br label %merge
merge:
  %l8 = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  %v8 = load atomic i32, ptr addrspace(1) %l8 unordered, align 4
  %l16 = getelementptr inbounds i8, ptr addrspace(1) %o, i64 16
  %v16 = load atomic i32, ptr addrspace(1) %l16 unordered, align 4
  call void @use(i32 %v8)
  call void @use(i32 %v16)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; Alloc eliminated; two independent i32 field PHIs (one per sparse offset).
; CHECK-LABEL: define void @test_field_phi_sparse_offsets
; CHECK-NOT: jeandle.new_instance
; CHECK: = phi i32
; CHECK: = phi i32
; CHECK: call void @use
; CHECK: call void @use

; Both PHIs have the same object and merge block, so the trace must carry the
; field offset to give each effect a semantic identity. The NOT checks make
; this an exact two-effect assertion rather than an at-least-two assertion.
; TRACE-NOT: PEA: CreatePHI function=@test_field_phi_sparse_offsets
; TRACE: PEA: CreatePHI function=@test_field_phi_sparse_offsets [VO=0] block=%merge offset=8
; TRACE-NEXT: PEA: CreatePHI function=@test_field_phi_sparse_offsets [VO=0] block=%merge offset=16
; TRACE-NOT: PEA: CreatePHI function=@test_field_phi_sparse_offsets

!java-method-compilation = !{}
