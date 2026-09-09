; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" \
; RUN:   %s -o %t.ir
; RUN: FileCheck %s < %t.ir
; RUN: sed -n '/^define ptr addrspace(1) @test_three_deep_cyclic/,/^}/p' %t.ir \
; RUN:   | grep -c '^  store atomic' | FileCheck %s --check-prefix=STORE-COUNT
; RUN: opt -disable-output -passes="require<partial-escape-analysis>" \
; RUN:   -jeandle-trace-pea -jeandle-dump-pea-stats \
; RUN:   -jeandle-pea-analyze-function=test_three_deep_cyclic %s > %t.trace 2>&1
; RUN: FileCheck %s --check-prefix=TRACE < %t.trace
; RUN: grep -c '^PEA: EliminateStore function=@test_three_deep_cyclic ' %t.trace \
; RUN:   | FileCheck %s --check-prefix=ELIMINATE-COUNT
; RUN: grep -c '^PEA: Materialize function=@test_three_deep_cyclic ' %t.trace \
; RUN:   | FileCheck %s --check-prefix=MATERIALIZE-COUNT

; Edge case: three-deep cyclic nested virtuals. A.x=B, B.x=C, C.x=A.
; Only A escapes (returned); B and C escape transitively. Under reuse-OrigAlloc
; all three OrigAllocs are KEPT (each dominates the single escape point), so
; every field store replays directly onto its OrigAlloc and the cycle resolves
; through the peer's OrigAlloc — no cascade coordination and no
; materialized-object PHI.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare i32 @__gxx_personality_v0(...)

define ptr addrspace(1) @test_three_deep_cyclic() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 11111 to ptr), i32 16, i1 false)
       to label %nA unwind label %u1
nA:
  %b = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 22222 to ptr), i32 16, i1 false)
       to label %nB unwind label %u2
nB:
  %c = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 33333 to ptr), i32 16, i1 false)
       to label %nC unwind label %u3
nC:
  %slotA = getelementptr inbounds i8, ptr addrspace(1) %a, i64 8
  store atomic ptr addrspace(1) %b, ptr addrspace(1) %slotA unordered, align 8
  %slotB = getelementptr inbounds i8, ptr addrspace(1) %b, i64 8
  store atomic ptr addrspace(1) %c, ptr addrspace(1) %slotB unordered, align 8
  %slotC = getelementptr inbounds i8, ptr addrspace(1) %c, i64 8
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %slotC unordered, align 8
  ret ptr addrspace(1) %a
u1:
  %lp1 = landingpad i64 cleanup
  resume i64 %lp1
u2:
  %lp2 = landingpad i64 cleanup
  resume i64 %lp2
u3:
  %lp3 = landingpad i64 cleanup
  resume i64 %lp3
}

; All three OrigAllocs are retained.
; CHECK-LABEL: define ptr addrspace(1) @test_three_deep_cyclic
; CHECK: %[[A:[A-Za-z0-9._]+]] = invoke hotspotcc{{.*}}ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 11111 to ptr), i32 16, i1 false)
; CHECK: %[[B:[A-Za-z0-9._]+]] = invoke hotspotcc{{.*}}ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 22222 to ptr), i32 16, i1 false)
; CHECK: %[[C:[A-Za-z0-9._]+]] = invoke hotspotcc{{.*}}ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 33333 to ptr), i32 16, i1 false)
; No additional allocation invoke is emitted.
; CHECK-NOT: pea.mat = invoke
; All three field groups use OrigAlloc values — the cycle's back edge C.x = A
; resolves through A's OrigAlloc (kept alive), never poison.
; CHECK-DAG: %[[A_SLOT:[A-Za-z0-9._]+]] = getelementptr inbounds{{( nuw)?}} i8, ptr addrspace(1) %[[A]], i64 8
; CHECK-DAG: store atomic ptr addrspace(1) %[[B]], ptr addrspace(1) %[[A_SLOT]] unordered, align 8
; CHECK-DAG: %[[B_SLOT:[A-Za-z0-9._]+]] = getelementptr inbounds{{( nuw)?}} i8, ptr addrspace(1) %[[B]], i64 8
; CHECK-DAG: store atomic ptr addrspace(1) %[[C]], ptr addrspace(1) %[[B_SLOT]] unordered, align 8
; CHECK-DAG: %[[C_SLOT:[A-Za-z0-9._]+]] = getelementptr inbounds{{( nuw)?}} i8, ptr addrspace(1) %[[C]], i64 8
; CHECK-DAG: store atomic ptr addrspace(1) %[[A]], ptr addrspace(1) %[[C_SLOT]] unordered, align 8
; CHECK-NOT: poison
; CHECK: ret ptr addrspace(1) %[[A]]

; TRACE-COUNT-3: PEA: EliminateStore function=@test_three_deep_cyclic
; TRACE-COUNT-3: PEA: Materialize function=@test_three_deep_cyclic
; TRACE: ;; PEA stats @test_three_deep_cyclic: NeverEscapes=0 PartiallyEscapes=3 AlwaysEscapes=0
; STORE-COUNT: {{^3$}}
; ELIMINATE-COUNT: {{^3$}}
; MATERIALIZE-COUNT: {{^3$}}

!java-method-compilation = !{}
