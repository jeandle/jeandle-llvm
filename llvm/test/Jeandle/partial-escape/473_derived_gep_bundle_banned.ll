; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Non-zero-offset GEP as a deopt-bundle operand: %g =
; gep(%o, 16) resolves to VO 0 but is a DERIVED pointer, NOT an identity —
; propagatePointerAlias registered it in the alias map unconditionally. The
; strengthened IsIdentityAlias check (alias-map hit AND
; resolveFieldOffset==0) bans it, so the VO is kept real and the GEP stays
; valid. Admitting it as identity would make the transform bail on the
; OrigAlloc scan and Pass 2 would produce `gep poison, 16`.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(i32)
declare i32 @__gxx_personality_v0(...)

define void @gep_in_bundle() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 11111 to ptr), i32 24, i1 false)
       to label %n unwind label %u
n:
  %g = getelementptr inbounds i8, ptr addrspace(1) %o, i64 16
  call void @sink(i32 0)
       [ "deopt"(i32 0, i32 0, i64 12, ptr addrspace(1) %g) ]
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; The derived bundle operand bans description: %o's allocation and %g
; survive verbatim; no descriptor, no poison.
; CHECK-LABEL: define void @gep_in_bundle(
; CHECK: invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK: %g = getelementptr inbounds i8, ptr addrspace(1) %o, i64 16
; CHECK: call void @sink(i32 0) [ "deopt"(i32 0, i32 0, i64 12, ptr addrspace(1) %g) ]
; CHECK-NOT: poison

!java-method-compilation = !{}
