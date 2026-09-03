; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Three-object cycle (o.f = p, p.g = q, q.h = o) escaping at a shared merge.
; Under reuse-OrigAlloc all three OrigAllocs are KEPT (each dominates the escape
; point), so every field store replays directly onto its OrigAlloc and the
; cycle's back edge q.h = o resolves through o's OrigAlloc — no cascade
; coordination, no additional allocation invoke, no materialized-object PHI.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @self_field_cycle3_perpred(i1 %c)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 11111 to ptr), i32 32, i1 false) to label %oi unwind label %u
oi:
  %p = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 22222 to ptr), i32 32, i1 false) to label %pi unwind label %u
pi:
  %q = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 33333 to ptr), i32 32, i1 false) to label %fld unwind label %u
fld:
  %of = getelementptr inbounds i8, ptr addrspace(1) %o, i64 0
  store atomic ptr addrspace(1) %p, ptr addrspace(1) %of unordered, align 8
  %pg = getelementptr inbounds i8, ptr addrspace(1) %p, i64 8
  store atomic ptr addrspace(1) %q, ptr addrspace(1) %pg unordered, align 8
  %qh = getelementptr inbounds i8, ptr addrspace(1) %q, i64 16
  store atomic ptr addrspace(1) %o, ptr addrspace(1) %qh unordered, align 8
  br i1 %c, label %left, label %right
left:
  br label %merge
right:
  br label %merge
merge:
  call void @sink(ptr addrspace(1) %o)
  call void @sink(ptr addrspace(1) %p)
  call void @sink(ptr addrspace(1) %q)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

!java-method-compilation = !{}

; CHECK-LABEL: define void @self_field_cycle3_perpred
; All three OrigAllocs (klass 11111 = o, 22222 = p, 33333 = q) are retained.
; CHECK-DAG: invoke hotspotcc{{.*}}@jeandle.new_instance(ptr inttoptr (i64 11111 to ptr)
; CHECK-DAG: invoke hotspotcc{{.*}}@jeandle.new_instance(ptr inttoptr (i64 22222 to ptr)
; CHECK-DAG: invoke hotspotcc{{.*}}@jeandle.new_instance(ptr inttoptr (i64 33333 to ptr)
; No additional allocation invoke is emitted.
; CHECK-NOT: pea.mat = invoke
; Replayed field stores use OrigAlloc values — the cycle's back edge q.h = o
; resolves through o's OrigAlloc (kept alive), never poison.
; CHECK: store atomic ptr addrspace(1) %o, ptr addrspace(1) %pea.matslot{{[0-9]*}} unordered, align 8
; CHECK: store atomic ptr addrspace(1) %q, ptr addrspace(1) %pea.matslot{{[0-9]*}} unordered, align 8
; CHECK: store atomic ptr addrspace(1) %p, ptr addrspace(1) %pea.matslot{{[0-9]*}} unordered, align 8
; CHECK-NOT: poison
; CHECK: ret void
