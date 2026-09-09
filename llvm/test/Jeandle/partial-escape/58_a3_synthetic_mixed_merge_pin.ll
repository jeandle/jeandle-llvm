; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s
; RUN: opt -disable-output \
; RUN:   -passes="require<partial-escape-analysis>,partial-escape-transform" \
; RUN:   -jeandle-dump-pea-stats \
; RUN:   -jeandle-pea-analyze-function=test_a3_synthetic_mixed %s 2>&1 \
; RUN:   | FileCheck %s --check-prefix=STATS

; A synthetic VO (created by Case C at %M1) flows into a downstream mixed PHI
; Case A. Its AllocationCall is borrowed from one source and must never be used
; as the replay receiver. Both source allocations remain at their original
; sites so %p is a real merged identity; the current merged field value is
; replayed onto %p only when the downstream merge makes that identity real.
;
; The general "alloc doesn't dominate merge" case in mergeStates' true-mixed
; branch is unreachable for non-synthetic VOs by SSA dominance: ID can only
; be tracked at every pred of a merge if its OrigAlloc reaches every pred via
; SSA, which by dominance requires OrigAlloc to dominate the merge. A
; debug-only assertion at that branch catches any future regression.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define ptr addrspace(1) @test_a3_synthetic_mixed(
        i1 %c0, i1 %c1, i1 %c2, i1 %c3, ptr addrspace(1) %arg)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  br i1 %c0, label %A, label %B
A:
  %oA = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %An unwind label %u
An:
  %af = getelementptr inbounds i8, ptr addrspace(1) %oA, i64 8
  store atomic i32 17, ptr addrspace(1) %af unordered, align 4
  br label %M1
B:
  %oB = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %Bn unwind label %u
Bn:
  %bf = getelementptr inbounds i8, ptr addrspace(1) %oB, i64 8
  store atomic i32 23, ptr addrspace(1) %bf unordered, align 4
  br label %M1
M1:
  ; Case C synthesizes a single VO aliased to %p.
  %p = phi ptr addrspace(1) [ %oA, %An ], [ %oB, %Bn ]
  br i1 %c1, label %X, label %Z
X:
  br i1 %c2, label %M2, label %N
Z:
  br i1 %c3, label %M2, label %W
M2:
  ; Mixed PHI Case A: %p (synthetic VO alias) on the X edge, %arg
  ; (non-virtual) on the Z edge.  This makes the already-merged Case-C
  ; identity real.
  %q = phi ptr addrspace(1) [ %p, %X ], [ %arg, %Z ]
  call void @sink(ptr addrspace(1) %q)
  ret ptr addrspace(1) %arg
W:
  br label %N
N:
  ret ptr addrspace(1) %arg
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; Both source allocations survive, but their pre-merge stores remain scalar
; replaced. The merged field PHI is replayed onto %p on the downstream incoming
; edges; there is no source-edge field replay and no new allocation.
; CHECK-LABEL: define ptr addrspace(1) @test_a3_synthetic_mixed
; CHECK: %oA = invoke hotspotcc{{.*}}@jeandle.new_instance
; CHECK: An:
; CHECK-NEXT: br label %M1
; CHECK: %oB = invoke hotspotcc{{.*}}@jeandle.new_instance
; CHECK: Bn:
; CHECK-NEXT: br label %M1
; CHECK: %p = phi ptr addrspace(1) [ %oA, %An ], [ %oB, %Bn ]
; CHECK-NEXT: %[[FIELD:[-A-Za-z$._0-9]+]] = phi i32 [ 17, %An ], [ 23, %Bn ]
; CHECK-NOT: store atomic i32 17
; CHECK-NOT: store atomic i32 23
; CHECK: %[[SLOT0:[-A-Za-z$._0-9]+]] = getelementptr inbounds i8, ptr addrspace(1) %p, i64 8
; CHECK-NEXT: store atomic i32 %[[FIELD]], ptr addrspace(1) %[[SLOT0]] unordered, align 4
; CHECK: %[[SLOT1:[-A-Za-z$._0-9]+]] = getelementptr inbounds i8, ptr addrspace(1) %p, i64 8
; CHECK-NEXT: store atomic i32 %[[FIELD]], ptr addrspace(1) %[[SLOT1]] unordered, align 4
; CHECK-NOT: getelementptr inbounds i8, ptr addrspace(1) %p, i64 8
; CHECK: %q = phi ptr addrspace(1) [ %p,
; CHECK: call void @sink(ptr addrspace(1) %q)
; CHECK-NOT: poison
; STATS: PEA stats @test_a3_synthetic_mixed: NeverEscapes=0 PartiallyEscapes=2 AlwaysEscapes=0

!java-method-compilation = !{}
