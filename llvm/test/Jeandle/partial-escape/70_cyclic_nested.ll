; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" \
; RUN:   %s -o %t.ir
; RUN: FileCheck %s < %t.ir
; RUN: sed -n '/^define ptr addrspace(1) @test_cyclic_nested/,/^}/p' %t.ir \
; RUN:   | grep -c '^  store atomic' | FileCheck %s --check-prefix=STORE-COUNT
; RUN: opt -disable-output -passes="require<partial-escape-analysis>" \
; RUN:   -jeandle-trace-pea -jeandle-dump-pea-stats \
; RUN:   -jeandle-pea-analyze-function=test_cyclic_nested %s > %t.trace 2>&1
; RUN: FileCheck %s --check-prefix=TRACE < %t.trace
; RUN: grep -c '^PEA: EliminateStore function=@test_cyclic_nested ' %t.trace \
; RUN:   | FileCheck %s --check-prefix=ELIMINATE-COUNT
; RUN: grep -c '^PEA: Materialize function=@test_cyclic_nested ' %t.trace \
; RUN:   | FileCheck %s --check-prefix=MATERIALIZE-COUNT

; Cyclic nested virtuals. Two virtuals A and B form a cycle —
; A.f = B and B.g = A. Returning A escapes A; B escapes transitively (A.f
; references it). Under reuse-OrigAlloc both OrigAllocs are KEPT (each
; dominates the single escape point), so every field store replays directly
; onto its OrigAlloc and the cycle resolves through the peer's OrigAlloc — no
; cascade coordination, no additional allocation, no materialized-object PHI.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare i32 @__gxx_personality_v0(...)

define ptr addrspace(1) @test_cyclic_nested() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 11111 to ptr), i32 16, i1 false)
       to label %nA unwind label %u1
nA:
  %b = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 22222 to ptr), i32 16, i1 false)
       to label %nB unwind label %u2
nB:
  %slotA = getelementptr inbounds i8, ptr addrspace(1) %a, i64 8
  store atomic ptr addrspace(1) %b, ptr addrspace(1) %slotA unordered, align 8
  %slotB = getelementptr inbounds i8, ptr addrspace(1) %b, i64 8
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %slotB unordered, align 8
  ret ptr addrspace(1) %a
u1:
  %lp1 = landingpad i64 cleanup
  resume i64 %lp1
u2:
  %lp2 = landingpad i64 cleanup
  resume i64 %lp2
}

; Both OrigAllocs (klass 11111 = A, klass 22222 = B) are retained.
; CHECK-LABEL: define ptr addrspace(1) @test_cyclic_nested
; CHECK: %[[A:[A-Za-z0-9._]+]] = invoke hotspotcc{{.*}}ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 11111 to ptr), i32 16, i1 false)
; CHECK: %[[B:[A-Za-z0-9._]+]] = invoke hotspotcc{{.*}}ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 22222 to ptr), i32 16, i1 false)
; No additional allocation invoke is emitted.
; CHECK-NOT: pea.mat = invoke
; Both field groups use OrigAlloc values — the back edge B.g = A resolves
; through A's OrigAlloc (kept alive), never poison. An already canonical
; source suffix is retained without requiring transform-generated SSA names.
; CHECK-DAG: %[[A_SLOT:[A-Za-z0-9._]+]] = getelementptr inbounds{{( nuw)?}} i8, ptr addrspace(1) %[[A]], i64 8
; CHECK-DAG: store atomic ptr addrspace(1) %[[B]], ptr addrspace(1) %[[A_SLOT]] unordered, align 8
; CHECK-DAG: %[[B_SLOT:[A-Za-z0-9._]+]] = getelementptr inbounds{{( nuw)?}} i8, ptr addrspace(1) %[[B]], i64 8
; CHECK-DAG: store atomic ptr addrspace(1) %[[A]], ptr addrspace(1) %[[B_SLOT]] unordered, align 8
; CHECK-NOT: poison
; CHECK: ret ptr addrspace(1) %[[A]]

; TRACE-COUNT-2: PEA: EliminateStore function=@test_cyclic_nested
; TRACE-COUNT-2: PEA: Materialize function=@test_cyclic_nested
; TRACE: ;; PEA stats @test_cyclic_nested: NeverEscapes=0 PartiallyEscapes=2 AlwaysEscapes=0
; STORE-COUNT: {{^2$}}
; ELIMINATE-COUNT: {{^2$}}
; MATERIALIZE-COUNT: {{^2$}}

!java-method-compilation = !{}
