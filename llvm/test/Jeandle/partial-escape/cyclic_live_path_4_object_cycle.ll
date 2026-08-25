; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" \
; RUN:   %s -o %t.ir
; RUN: FileCheck %s < %t.ir
; RUN: sed -n '/^define ptr addrspace(1) @cyclic_live_path_4_object_cycle/,/^}/p' %t.ir \
; RUN:   | grep -c '^  store atomic' | FileCheck %s --check-prefix=STORE-COUNT
; RUN: opt -disable-output -passes="require<partial-escape-analysis>" \
; RUN:   -jeandle-trace-pea -jeandle-dump-pea-stats \
; RUN:   -jeandle-pea-analyze-function=cyclic_live_path_4_object_cycle %s > %t.trace 2>&1
; RUN: FileCheck %s --check-prefix=TRACE < %t.trace
; RUN: grep -c '^PEA: EliminateStore function=@cyclic_live_path_4_object_cycle ' %t.trace \
; RUN:   | FileCheck %s --check-prefix=ELIMINATE-COUNT
; RUN: grep -c '^PEA: Materialize function=@cyclic_live_path_4_object_cycle ' %t.trace \
; RUN:   | FileCheck %s --check-prefix=MATERIALIZE-COUNT

; Four-object cycle: A.f = B, B.g = C, C.h = D, D.i = A. Returning A escapes the
; whole group (4 objects, one shared escape point). Under reuse-OrigAlloc all
; four OrigAllocs are KEPT (each dominates the escape point), so every field
; store replays directly onto its OrigAlloc and the back edge D.i = A resolves
; through A's OrigAlloc — no cascade coordination, no new allocation invoke,
; no materialized-object PHI. Larger group than the 2-/3-object cyclic tests.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare i32 @__gxx_personality_v0(...)

define ptr addrspace(1) @cyclic_live_path_4_object_cycle()
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 11111 to ptr), i32 16, i1 false) to label %na unwind label %u1
na:
  %b = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 22222 to ptr), i32 16, i1 false) to label %nb unwind label %u2
nb:
  %c = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 33333 to ptr), i32 16, i1 false) to label %nc unwind label %u3
nc:
  %d = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 44444 to ptr), i32 16, i1 false) to label %nd unwind label %u4
nd:
  %sa = getelementptr inbounds i8, ptr addrspace(1) %a, i64 8
  store atomic ptr addrspace(1) %b, ptr addrspace(1) %sa unordered, align 8
  %sb = getelementptr inbounds i8, ptr addrspace(1) %b, i64 8
  store atomic ptr addrspace(1) %c, ptr addrspace(1) %sb unordered, align 8
  %sc = getelementptr inbounds i8, ptr addrspace(1) %c, i64 8
  store atomic ptr addrspace(1) %d, ptr addrspace(1) %sc unordered, align 8
  %sd = getelementptr inbounds i8, ptr addrspace(1) %d, i64 8
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %sd unordered, align 8
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
u4:
  %lp4 = landingpad i64 cleanup
  resume i64 %lp4
}

!java-method-compilation = !{}

; CHECK-LABEL: define ptr addrspace(1) @cyclic_live_path_4_object_cycle
; CHECK: %[[A:[A-Za-z0-9._]+]] = invoke hotspotcc{{.*}}@jeandle.new_instance(ptr inttoptr (i64 11111 to ptr)
; CHECK: %[[B:[A-Za-z0-9._]+]] = invoke hotspotcc{{.*}}@jeandle.new_instance(ptr inttoptr (i64 22222 to ptr)
; CHECK: %[[C:[A-Za-z0-9._]+]] = invoke hotspotcc{{.*}}@jeandle.new_instance(ptr inttoptr (i64 33333 to ptr)
; CHECK: %[[D:[A-Za-z0-9._]+]] = invoke hotspotcc{{.*}}@jeandle.new_instance(ptr inttoptr (i64 44444 to ptr)
; Materialization emits no new allocation invoke.
; CHECK-NOT: pea.mat = invoke
; All four field groups use OrigAlloc values (no poison): the back edge D.i = A
; resolves through A's OrigAlloc (kept alive).
; CHECK-DAG: %[[A_SLOT:[A-Za-z0-9._]+]] = getelementptr inbounds{{( nuw)?}} i8, ptr addrspace(1) %[[A]], i64 8
; CHECK-DAG: store atomic ptr addrspace(1) %[[B]], ptr addrspace(1) %[[A_SLOT]] unordered, align 8
; CHECK-DAG: %[[B_SLOT:[A-Za-z0-9._]+]] = getelementptr inbounds{{( nuw)?}} i8, ptr addrspace(1) %[[B]], i64 8
; CHECK-DAG: store atomic ptr addrspace(1) %[[C]], ptr addrspace(1) %[[B_SLOT]] unordered, align 8
; CHECK-DAG: %[[C_SLOT:[A-Za-z0-9._]+]] = getelementptr inbounds{{( nuw)?}} i8, ptr addrspace(1) %[[C]], i64 8
; CHECK-DAG: store atomic ptr addrspace(1) %[[D]], ptr addrspace(1) %[[C_SLOT]] unordered, align 8
; CHECK-DAG: %[[D_SLOT:[A-Za-z0-9._]+]] = getelementptr inbounds{{( nuw)?}} i8, ptr addrspace(1) %[[D]], i64 8
; CHECK-DAG: store atomic ptr addrspace(1) %[[A]], ptr addrspace(1) %[[D_SLOT]] unordered, align 8
; CHECK-NOT: poison
; CHECK: ret ptr addrspace(1) %[[A]]

; TRACE-COUNT-4: PEA: EliminateStore function=@cyclic_live_path_4_object_cycle
; TRACE-COUNT-4: PEA: Materialize function=@cyclic_live_path_4_object_cycle
; TRACE: ;; PEA stats @cyclic_live_path_4_object_cycle: NeverEscapes=0 PartiallyEscapes=4 AlwaysEscapes=0
; STORE-COUNT: {{^4$}}
; ELIMINATE-COUNT: {{^4$}}
; MATERIALIZE-COUNT: {{^4$}}
