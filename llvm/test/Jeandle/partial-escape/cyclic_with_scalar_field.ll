; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" \
; RUN:   %s -o %t.ir
; RUN: FileCheck %s < %t.ir
; RUN: sed -n '/^define ptr addrspace(1) @cyclic_with_scalar_field/,/^}/p' %t.ir \
; RUN:   | grep -c '^  store atomic' | FileCheck %s --check-prefix=STORE-COUNT
; RUN: opt -disable-output -passes="require<partial-escape-analysis>" \
; RUN:   -jeandle-trace-pea -jeandle-dump-pea-stats \
; RUN:   -jeandle-pea-analyze-function=cyclic_with_scalar_field %s > %t.trace 2>&1
; RUN: FileCheck %s --check-prefix=TRACE < %t.trace
; RUN: grep -c '^PEA: EliminateStore function=@cyclic_with_scalar_field ' %t.trace \
; RUN:   | FileCheck %s --check-prefix=ELIMINATE-COUNT
; RUN: grep -c '^PEA: Materialize function=@cyclic_with_scalar_field ' %t.trace \
; RUN:   | FileCheck %s --check-prefix=MATERIALIZE-COUNT

; A cyclic field graph with a non-peer SCALAR field: A.x = 42 (offset 0, i64)
; alongside A.f = B (offset 8) and B.g = A (offset 8, back edge). Returning A
; escapes the group. Under reuse-OrigAlloc both OrigAllocs are KEPT; all three
; stores replay onto OrigAllocs — the scalar store uses the constant 42, the two
; reference stores use OrigAlloc values (the back edge B.g = A resolves through
; A's OrigAlloc). Exercises FieldValue::isScalar and isMaterializedRef.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare i32 @__gxx_personality_v0(...)

define ptr addrspace(1) @cyclic_with_scalar_field()
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 11111 to ptr), i32 16, i1 false) to label %na unwind label %u1
na:
  %b = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 22222 to ptr), i32 16, i1 false) to label %nb unwind label %u2
nb:
  %sx = getelementptr inbounds i8, ptr addrspace(1) %a, i64 0
  store atomic i64 42, ptr addrspace(1) %sx unordered, align 8
  %sa = getelementptr inbounds i8, ptr addrspace(1) %a, i64 8
  store atomic ptr addrspace(1) %b, ptr addrspace(1) %sa unordered, align 8
  %sb = getelementptr inbounds i8, ptr addrspace(1) %b, i64 8
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %sb unordered, align 8
  ret ptr addrspace(1) %a
u1:
  %lp1 = landingpad i64 cleanup
  resume i64 %lp1
u2:
  %lp2 = landingpad i64 cleanup
  resume i64 %lp2
}

!java-method-compilation = !{}

; CHECK-LABEL: define ptr addrspace(1) @cyclic_with_scalar_field
; CHECK: %[[A:[A-Za-z0-9._]+]] = invoke hotspotcc{{.*}}@jeandle.new_instance(ptr inttoptr (i64 11111 to ptr)
; CHECK: %[[B:[A-Za-z0-9._]+]] = invoke hotspotcc{{.*}}@jeandle.new_instance(ptr inttoptr (i64 22222 to ptr)
; Materialization emits no new allocation invoke.
; CHECK-NOT: pea.mat = invoke
; The scalar field (A.x = 42) remains in A's exact field group, and both
; reference stores use OrigAlloc values (the back edge B.g = A resolves through
; A's OrigAlloc). Complete groups are CHECK-DAG because their order is not
; significant.
; CHECK-DAG: %[[A_SCALAR:[A-Za-z0-9._]+]] = getelementptr inbounds{{( nuw)?}} i8, ptr addrspace(1) %[[A]], i64 0
; CHECK-DAG: store atomic i64 42, ptr addrspace(1) %[[A_SCALAR]] unordered, align 8
; CHECK-DAG: %[[A_REF:[A-Za-z0-9._]+]] = getelementptr inbounds{{( nuw)?}} i8, ptr addrspace(1) %[[A]], i64 8
; CHECK-DAG: store atomic ptr addrspace(1) %[[B]], ptr addrspace(1) %[[A_REF]] unordered, align 8
; CHECK-DAG: %[[B_REF:[A-Za-z0-9._]+]] = getelementptr inbounds{{( nuw)?}} i8, ptr addrspace(1) %[[B]], i64 8
; CHECK-DAG: store atomic ptr addrspace(1) %[[A]], ptr addrspace(1) %[[B_REF]] unordered, align 8
; CHECK-NOT: poison
; CHECK: ret ptr addrspace(1) %[[A]]

; TRACE-COUNT-3: PEA: EliminateStore function=@cyclic_with_scalar_field
; TRACE-COUNT-2: PEA: Materialize function=@cyclic_with_scalar_field
; TRACE: ;; PEA stats @cyclic_with_scalar_field: NeverEscapes=0 PartiallyEscapes=2 AlwaysEscapes=0
; STORE-COUNT: {{^3$}}
; ELIMINATE-COUNT: {{^3$}}
; MATERIALIZE-COUNT: {{^2$}}
