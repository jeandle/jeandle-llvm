; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Mutual reference (o.f = p, p.g = o) escaping at a shared merge. Under
; reuse-OrigAlloc both OrigAllocs are KEPT (each dominates the escape point),
; so every field store replays directly onto its OrigAlloc and the back edge
; p.g = o resolves through o's OrigAlloc — no cascade coordination, no
; additional allocation invoke, no materialized-object PHI.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @mutual_field_perpred(i1 %c)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 11111 to ptr), i32 16, i1 false) to label %oi unwind label %u
oi:
  %p = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 22222 to ptr), i32 16, i1 false) to label %fld unwind label %u
fld:
  %of = getelementptr inbounds i8, ptr addrspace(1) %o, i64 0
  store atomic ptr addrspace(1) %p, ptr addrspace(1) %of unordered, align 8
  %pg = getelementptr inbounds i8, ptr addrspace(1) %p, i64 8
  store atomic ptr addrspace(1) %o, ptr addrspace(1) %pg unordered, align 8
  br i1 %c, label %left, label %right
left:
  br label %merge
right:
  br label %merge
merge:
  call void @sink(ptr addrspace(1) %o)
  call void @sink(ptr addrspace(1) %p)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

!java-method-compilation = !{}

; CHECK-LABEL: define void @mutual_field_perpred
; Both OrigAllocs (klass 11111 = o, klass 22222 = p) are retained.
; CHECK-DAG: invoke hotspotcc{{.*}}@jeandle.new_instance(ptr inttoptr (i64 11111 to ptr)
; CHECK-DAG: invoke hotspotcc{{.*}}@jeandle.new_instance(ptr inttoptr (i64 22222 to ptr)
; No additional allocation invoke is emitted.
; CHECK-NOT: pea.mat = invoke
; Replayed field stores use OrigAlloc values — the back edge p.g = o resolves
; through o's OrigAlloc (kept alive), never poison.
; CHECK: store atomic ptr addrspace(1) %o, ptr addrspace(1) %pea.matslot{{[0-9]*}} unordered, align 8
; CHECK: store atomic ptr addrspace(1) %p, ptr addrspace(1) %pea.matslot{{[0-9]*}} unordered, align 8
; CHECK-NOT: poison
; CHECK: call void @sink(ptr addrspace(1) %o)
; CHECK: call void @sink(ptr addrspace(1) %p)
; CHECK: ret void
