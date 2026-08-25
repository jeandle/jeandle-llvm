; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; PEA deopt support, simplest case: a SINGLE never-escaping
; instance object whose pointer is referenced ONLY in the "deopt" operand
; bundle of a safepoint call. Its two fields are scalar (non-reference).
;
; The object is truly never-escape: %o is NOT passed to @sink as a call
; argument (only the scalarized field values are). %o is observable solely
; through the deopt bundle, so HotSpot must be able to reallocate it at
; deopt. A never-escaping virtual object that is still virtual at the
; safepoint must be described by a virtual-object (VO) descriptor in the
; deopt bundle (ScalarValueType header + klass + field values), and the
; bundle slot that held OrigAlloc must become a VORefType reference to
; that descriptor. The OrigAlloc invoke itself is eliminated.
;
; Before the deopt support landed, the OrigAlloc reference in the bundle
; was left for Pass 2's poison-RAUW (or scrubbed to null), so HotSpot had
; no way to reallocate the object. This test pins the new contract.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(i32, i32)
declare i32 @__gxx_personality_v0(...)

define void @never_escape_vo_in_deopt(i32 %a, i32 %b) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 24, i1 false)
       to label %n unwind label %u
n:
  %s1 = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  %s2 = getelementptr inbounds i8, ptr addrspace(1) %o, i64 16
  store atomic i32 %a, ptr addrspace(1) %s1 unordered, align 4
  store atomic i32 %b, ptr addrspace(1) %s2 unordered, align 4
  %v1 = load atomic i32, ptr addrspace(1) %s1 unordered, align 4
  %v2 = load atomic i32, ptr addrspace(1) %s2 unordered, align 4
  ; Only %v1/%v2 (scalars) reach @sink; %o lives solely in the deopt
  ; bundle. The bundle carries a duplicated-BCI marker (i32 99, i32 99)
  ; then one locals entry: enc(LocalType, index=0, T_OBJECT)=12 followed
  ; by the OrigAlloc pointer %o.
  call void @sink(i32 %v1, i32 %v2)
       [ "deopt"(i32 99, i32 99, i64 12, ptr addrspace(1) %o) ]
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @never_escape_vo_in_deopt
; The OrigAlloc invoke is eliminated (NeverEscapes).
; CHECK-NOT: jeandle.new_instance
; The surviving sink call still carries a "deopt" bundle, but the slot
; that held OrigAlloc is now a VORefType reference, and a ScalarValueType
; VO descriptor (klass 12345 + the two scalar field values %a, %b) is
; appended after the duplicated-BCI marker.
;
; VORefLocalType slot encoding (vo_id=0): (0<<32)|(8<<16)|12 = 524300
; CHECK: call void @sink(i32 %a, i32 %b)
; CHECK-SAME: [ "deopt"(
; duplicated-BCI marker preserved.
; CHECK-SAME: i32 99, i32 99,
; ScalarValueType VO descriptor header (vo_id=0): (0<<32)|(4<<16)|12 = 262156
; CHECK-SAME: i64 262156, i64 12345, i32 2,
; field 0 (offset 8, LocalType/T_INT): (8<<32)|10 = 34359738378 -> value %a
; CHECK-SAME: i64 34359738378, i32 %a,
; field 1 (offset 16, LocalType/T_INT): (16<<32)|10 = 68719476746 -> value %b
; CHECK-SAME: i64 68719476746, i32 %b,
; the OrigAlloc locals slot is replaced by a VORefLocalType reference
; (enc 524300) followed by vo_id i32 0.
; CHECK-SAME: i64 524300, i32 0) ]
; The eliminated OrigAlloc must not appear (no poison, no %o) in the bundle.
; CHECK-NOT: addrspace(1) %o

!java-method-compilation = !{}
