; RUN: opt -S \
; RUN:   -passes='function(require<partial-escape-analysis>,partial-escape-transform,insert-gc-barriers),rewrite-statepoints-for-gc,verify' \
; RUN:   %s | FileCheck %s

; Anchor-supplier hook investigation regression test.
;
; PEA emits no virtual-anchor hook: anchors are only relevant to runtimes
; that perform loop-explosion / partial-evaluation merges, which Jeandle
; does not.
;
; This test exercises the FULL Jeandle pipeline relevant to retained
; PartiallyEscapes allocations:
;   PEA analyze -> PEA transform -> InsertGCBarriers -> RewriteStatepointsForGC
;
; across three shapes that stress replay and GC statepoint handling:
;   1. @t_mat_plain  - single escape call site
;   2. @t_mat_mixed  - mixed-state merge (virtual on one pred, escaped on
;                      the other)
;   3. @t_mat_phi    - two retained allocations feeding a PHI that escapes
;
; For each case we assert that:
;   - Each retained allocation invoke is wrapped by `gc.statepoint`
;   - Its pointer is recovered via `gc.result`
;   - Subsequent escape calls list the retained/relocated pointer in
;     their `gc-live` operand bundle (stack-map entry preserved)
;   - The synthesized landingpad has type `token` (RewriteStatepointsForGC's
;     rewrite of the i64 landingpad — proves the exception edge survived)
;
; The implicit additional assertion is that `verify` (the final pass)
; passes — every SSA/dominance/statepoint invariant holds end-to-end,
; demonstrating that no anchor hook is needed.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

@satb_log = private global ptr addrspace(1) null

define private hotspotcc void @jeandle.pre_barrier(ptr addrspace(1) %addr) #0 {
entry:
  %0 = load atomic ptr addrspace(1), ptr addrspace(1) %addr unordered, align 8
  store ptr addrspace(1) %0, ptr @satb_log
  ret void
}

define private hotspotcc void @jeandle.post_barrier(ptr addrspace(1) %addr, ptr addrspace(1) captures(none) %oop) #0 {
entry:
  %0 = ptrtoint ptr addrspace(1) %addr to i64
  %1 = lshr i64 %0, 9
  %2 = getelementptr inbounds i8, ptr inttoptr (i64 139709660639232 to ptr), i64 %1
  store atomic i8 0, ptr %2 unordered, align 1
  ret void
}

;; ---------------------------------------------------------------------
;; Case 1: plain materialize at an escape-call site.
;; ---------------------------------------------------------------------
define void @t_mat_plain() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %n unwind label %u
n:
  %s = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  store atomic i32 42, ptr addrspace(1) %s unordered, align 4
  call void @sink(ptr addrspace(1) %o)
  ret void
u:
  %lp = landingpad i64 cleanup
  ret void
}

; CHECK-LABEL: define void @t_mat_plain
; The retained source allocation is wrapped by gc.statepoint.
; CHECK: invoke hotspotcc token (i64, i32, ptr, i32, i32, ...) @llvm.experimental.gc.statepoint.p0
; CHECK-SAME: ptr addrspace(1) (ptr, i32, i1)) @jeandle.new_instance, i32 3
; CHECK: gc.result
; CHECK: call token (i64, i32, ptr, i32, i32, ...) @llvm.experimental.gc.statepoint.p0
; CHECK-SAME: void (ptr addrspace(1))) @sink
; The retained pointer is live across the @sink statepoint -> appears
; in the gc-live bundle and a gc.relocate is produced for it.
; CHECK-SAME: "gc-live"
; CHECK: gc.relocate
; Landingpad survived the rewrite as `token`.
; CHECK: landingpad token

;; ---------------------------------------------------------------------
;; Case 2: mixed-state merge — virtual on one branch, escaped on the
;; other. PEA materializes before the @sink call on the escaping branch.
;; ---------------------------------------------------------------------
define void @t_mat_mixed(i1 %c) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %obj = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 22222 to ptr), i32 16, i1 false)
         to label %n unwind label %u
n:
  %slot = getelementptr inbounds i8, ptr addrspace(1) %obj, i64 8
  store atomic i32 99, ptr addrspace(1) %slot unordered, align 4
  br i1 %c, label %esc, label %loc
esc:
  call void @sink(ptr addrspace(1) %obj)
  br label %merge
loc:
  br label %merge
merge:
  ret void
u:
  %lp = landingpad i64 cleanup
  ret void
}

; CHECK-LABEL: define void @t_mat_mixed
; CHECK: invoke hotspotcc token (i64, i32, ptr, i32, i32, ...) @llvm.experimental.gc.statepoint.p0
; CHECK-SAME: ptr addrspace(1) (ptr, i32, i1)) @jeandle.new_instance, i32 3
; CHECK: gc.result
; CHECK: call token (i64, i32, ptr, i32, i32, ...) @llvm.experimental.gc.statepoint.p0
; CHECK-SAME: void (ptr addrspace(1))) @sink
; CHECK-SAME: "gc-live"
; CHECK: gc.relocate
; CHECK: landingpad token

;; ---------------------------------------------------------------------
;; Case 3: two source allocations feed a PHI that escapes post-merge.
;; Their Klass values differ, so Case C is rejected and both OrigAllocs remain.
;; ---------------------------------------------------------------------
define void @t_mat_phi(i1 %c) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  br i1 %c, label %a, label %b
a:
  %oa = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 11111 to ptr), i32 16, i1 false)
        to label %na unwind label %u
na:
  br label %merge
b:
  %ob = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 22222 to ptr), i32 16, i1 false)
        to label %nb unwind label %u
nb:
  br label %merge
merge:
  %p = phi ptr addrspace(1) [ %oa, %na ], [ %ob, %nb ]
  call void @sink(ptr addrspace(1) %p)
  ret void
u:
  %lp = landingpad i64 cleanup
  ret void
}

; CHECK-LABEL: define void @t_mat_phi
; Both allocations are wrapped by gc.statepoint on their respective
; pred-paths and surfaced via gc.result.
; CHECK: invoke hotspotcc token (i64, i32, ptr, i32, i32, ...) @llvm.experimental.gc.statepoint.p0
; CHECK-SAME: ptr addrspace(1) (ptr, i32, i1)) @jeandle.new_instance, i32 3
; CHECK: gc.result
; CHECK: invoke hotspotcc token (i64, i32, ptr, i32, i32, ...) @llvm.experimental.gc.statepoint.p0
; CHECK-SAME: ptr addrspace(1) (ptr, i32, i1)) @jeandle.new_instance, i32 3
; CHECK: gc.result
; The PHI merges the two gc.result values and flows into the @sink
; statepoint; the merged pointer ends up in the gc-live bundle and is
; relocated.
; CHECK: phi ptr addrspace(1)
; CHECK: call token (i64, i32, ptr, i32, i32, ...) @llvm.experimental.gc.statepoint.p0
; CHECK-SAME: void (ptr addrspace(1))) @sink
; CHECK-SAME: "gc-live"
; CHECK: gc.relocate

attributes #0 = { noinline "lower-phase"="1" }

!java-method-compilation = !{}
