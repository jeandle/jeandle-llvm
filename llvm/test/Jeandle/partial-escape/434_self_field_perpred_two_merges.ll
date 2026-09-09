; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Self-referential field (o.f = o) materialized at TWO escape edges from the
; same virtual predecessor. `else` branches to `merge` and `S`, and o is
; virtual on both edges, so under reuse-OrigAlloc the single OrigAlloc is kept
; alive and the self-referential field replays ONCE PER escaping edge (two
; replayed stores onto OrigAlloc). No additional allocation or
; materialized-object PHI is needed at either merge — OrigAlloc is the single
; SSA value.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @self_field_perpred_two_merges(i1 %c, i1 %c2)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 12345 to ptr), i32 16, i1 false) to label %n unwind label %u
n:
  br i1 %c, label %then, label %else
then:
  call void @sink(ptr addrspace(1) %o)
  br label %merge
else:
  %slot = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  store atomic ptr addrspace(1) %o, ptr addrspace(1) %slot unordered, align 8
  br i1 %c2, label %merge, label %S
merge:
  br label %S
S:
  call void @sink(ptr addrspace(1) %o)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

!java-method-compilation = !{}

; CHECK-LABEL: define void @self_field_perpred_two_merges
; Exactly one allocation invoke (the original OrigAlloc, retained).
; CHECK: invoke hotspotcc{{.*}}@jeandle.new_instance(ptr inttoptr (i64 12345 to ptr)
; CHECK-NOT: pea.mat = invoke
; The self-referential field replays once per escaping edge off `else` — two
; stores, both with the live OrigAlloc %o as the value (no <badref>, no poison).
; CHECK: store atomic ptr addrspace(1) %o, ptr addrspace(1) %pea.matslot unordered, align 8
; CHECK: store atomic ptr addrspace(1) %o, ptr addrspace(1) %pea.matslot{{[0-9]*}} unordered, align 8
; No materialized-object PHI: OrigAlloc is the single SSA value.
; CHECK-NOT: phi
; CHECK: call void @sink(ptr addrspace(1) %o)
; CHECK: ret void
