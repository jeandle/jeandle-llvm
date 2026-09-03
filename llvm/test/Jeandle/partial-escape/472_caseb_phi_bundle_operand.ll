; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Case-B PHI as a deopt-bundle operand. %p = phi(%o, %o) is a Case-B alias
; of VO 0 — object IDENTITY, not a derived pointer — so VO 0 is describable
; and %p's bundle slot must be rewritten to a VORef. The analysis records the exact
; exact root occurrence in the complete pool plan; the PHI itself
; is erased as redundant (its only remaining use was the bundle slot).

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(i32)
declare i32 @__gxx_personality_v0(...)

define void @caseb_phi_in_bundle(i32 %x, i1 %c) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 100 to ptr), i32 16, i1 false)
       to label %n1 unwind label %u
n1:
  %of = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  store atomic i32 %x, ptr addrspace(1) %of unordered, align 4
  br i1 %c, label %t, label %f
t:
  br label %m
f:
  br label %m
m:
  ; Case-B PHI: both incomings resolve to VO 0 -> aliased to VO 0.
  %p = phi ptr addrspace(1) [ %o, %t ], [ %o, %f ]
  ; Safepoint references the PHI (identity for VO 0). VO 0 NeverEscapes.
  call void @sink(i32 %x)
       [ "deopt"(i32 99, i32 99, i64 12, ptr addrspace(1) %p) ]
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; VO 0 is NeverEscapes and described. Descriptor (vo_id=0, ScalarValueType,
; T_OBJECT): (0<<32)|(4<<16)|12 = 262156; field (offset 8, LocalType/T_INT):
; (8<<32)|10 = 34359738378 -> %x; the %p slot becomes a VORefLocalType:
; (0<<32)|(8<<16)|12 = 524300, then i32 0. No poison, no PHI left.
; CHECK-LABEL: define void @caseb_phi_in_bundle(
; CHECK-NOT: jeandle.new_instance
; CHECK-NOT: %p = phi
; CHECK: call void @sink(i32 %x)
; CHECK-SAME: [ "deopt"(i32 99, i32 99, i64 262156, i64 100, i32 1, i64 34359738378, i32 %x, i64 524300, i32 0) ]
; CHECK-NOT: poison

!java-method-compilation = !{}
