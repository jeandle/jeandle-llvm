; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Dangling field snapshot, deopt descriptor path. Scalar load
; from a virtual VO stored into another virtual VO (o.f = p.g), then the
; outer VO is described in a deopt bundle. The folded load (%lg) gets a
; scalar alias + a ReplaceLoad effect that erases it in Pass 1;
; the whole-pool rewrite must emit the NORMALIZED terminal %x in
; the VO descriptor, not the freed %lg.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(i32)
declare i32 @__gxx_personality_v0(...)

define void @scalar_folded_load_in_descriptor(i32 %x) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %p = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 100 to ptr), i32 16, i1 false)
       to label %n1 unwind label %u
n1:
  %pf = getelementptr inbounds i8, ptr addrspace(1) %p, i64 8
  store atomic i32 %x, ptr addrspace(1) %pf unordered, align 4
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 200 to ptr), i32 16, i1 false)
       to label %n2 unwind label %u
n2:
  %of = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  %lg = load atomic i32, ptr addrspace(1) %pf unordered, align 4
  ; o.f = p.g  (p.g folds to %x; %lg gets a scalar alias + ReplaceLoad effect)
  store atomic i32 %lg, ptr addrspace(1) %of unordered, align 4
  ; o lives only in the deopt bundle (NeverEscapes, describable).
  call void @sink(i32 %x)
       [ "deopt"(i32 99, i32 99, i64 12, ptr addrspace(1) %o) ]
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; Both VOs are NeverEscapes (eliminated). Only %o is reachable from the bundle,
; so the canonical deopt pool contains one descriptor with wire ID 0.
; Descriptor %o (wire ID 0, ScalarValueType, T_OBJECT):
; (0<<32)|(4<<16)|12 = 262156.
; CHECK-LABEL: define void @scalar_folded_load_in_descriptor(
; CHECK-NOT: jeandle.new_instance
; CHECK: call void @sink(i32 %x)
; CHECK-SAME: [ "deopt"(i32 99, i32 99,
; CHECK-SAME: i64 262156, i64 200, i32 1,
; field (offset 8, LocalType/T_INT): (8<<32)|10 = 34359738378 -> value %x (the
; normalized terminal, NOT the erased %lg)
; CHECK-SAME: i64 34359738378, i32 %x,
; the locals root becomes a VORefLocalType reference to wire ID 0:
; (0<<32)|(8<<16)|12 = 524300, followed by i32 0.
; CHECK-SAME: i64 524300, i32 0) ]
; CHECK-NOT: poison

!java-method-compilation = !{}
