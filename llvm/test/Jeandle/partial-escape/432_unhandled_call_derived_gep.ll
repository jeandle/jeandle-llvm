; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Generic dispatch fallback (processInstruction) under the reuse-OrigAlloc
; model: an UNHANDLED call consuming a derived-GEP operand of a virtual object.
;
; t_derived_off16 / t_derived_off0: the call MATERIALIZES the object at the
; call (unconditional, per operand; there is no
; derived-operand special case, so an offset-0 derived GEP is materialized
; exactly like a non-zero one). Under reuse-OrigAlloc the materialized value
; IS OrigAlloc, which dominates the pre-computed GEP, so the derived
; argument stays valid: %o is retained (PartiallyEscapes), the GEP keeps its
; real base %o, and the call keeps the derived %g. t_derived_off16 has a
; tracked store (42), which is replayed onto OrigAlloc via pea.matslot
; immediately before the call; t_derived_off0 tracks nothing, so its IR is
; unchanged.
;
; t_whole_object: a whole-object call argument is OrigAlloc directly. Under
; reuse-OrigAlloc the object escapes via @external(%o): the original %o is
; retained and consumed directly; materialization introduces no new invoke.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @external(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @t_derived_off16() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 32, i1 false)
         to label %n unwind label %u
n:
  %g = getelementptr inbounds i8, ptr addrspace(1) %o, i64 16
  store atomic i32 42, ptr addrspace(1) %g unordered, align 4
  call void @external(ptr addrspace(1) %g)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

define void @t_derived_off0() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 32, i1 false)
         to label %n unwind label %u
n:
  %g = getelementptr inbounds i8, ptr addrspace(1) %o, i64 0
  call void @external(ptr addrspace(1) %g)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

define void @t_whole_object() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 32, i1 false)
         to label %n unwind label %u
n:
  call void @external(ptr addrspace(1) %o)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; Derived-operand calls: the object materializes at the call (PartiallyEscapes)
; and the GEP keeps a real base. CHECK-NOT poison right after each LABEL so
; its scope spans the body where a poison-GEP regression would appear.
; CHECK-LABEL: define void @t_derived_off16
; CHECK-NOT: getelementptr{{.*}}poison
; CHECK: invoke{{.*}}@jeandle.new_instance
; The tracked store is replayed onto OrigAlloc immediately before the call.
; CHECK: %pea.matslot = getelementptr inbounds i8, ptr addrspace(1) %o, i64 16
; CHECK: store atomic i32 42, ptr addrspace(1) %pea.matslot unordered, align 4
; CHECK: call void @external(ptr addrspace(1) %g)

; CHECK-LABEL: define void @t_derived_off0
; CHECK-NOT: getelementptr{{.*}}poison
; CHECK: invoke{{.*}}@jeandle.new_instance
; CHECK: call void @external(ptr addrspace(1) %g)

; Whole-object call: OrigAlloc %o retained and consumed directly; no new
; invoke is introduced.
; CHECK-LABEL: define void @t_whole_object
; CHECK: invoke{{.*}}@jeandle.new_instance
; CHECK: call void @external(ptr addrspace(1) %o)
; CHECK-NOT: pea.mat = invoke

!java-method-compilation = !{}
