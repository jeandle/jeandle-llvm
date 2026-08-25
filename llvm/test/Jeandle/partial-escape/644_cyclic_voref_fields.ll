; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Cyclic / forward-reference VORef fields. VO %a (klass 100) holds a
; reference to %b at offset 8 and a scalar at offset 16; VO %b (klass 200)
; holds a reference to %a at offset 8 and a scalar at offset 16. So a.f=b AND
; b.g=a — a mutual cycle. Both are never-escaping and virtual at the safepoint,
; and BOTH are direct deopt-bundle slots (roots).
;
; Both must be described, each with a VORef FIELD pointing at the other. The
; analyzer's greatest-fixpoint keeps both describable (a cycle where every
; member is describable is stable). On the HotSpot parse side the descriptor
; order forces a forward reference (the second-applied descriptor is emitted
; first), which the two-pass / deferred VORef-field resolution must handle —
; validated end-to-end by a jtreg test; this lit pins the LLVM emit contract.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(i32, i32)
declare i32 @__gxx_personality_v0(...)

define void @cyclic_voref_fields(i32 %x, i32 %y) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 100 to ptr), i32 24, i1 false)
       to label %alloc_b unwind label %u
alloc_b:
  %b = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 200 to ptr), i32 24, i1 false)
       to label %body unwind label %u
body:
  ; a: offset 8 = ref %b, offset 16 = int %x
  %af1 = getelementptr inbounds i8, ptr addrspace(1) %a, i64 8
  %af2 = getelementptr inbounds i8, ptr addrspace(1) %a, i64 16
  store atomic ptr addrspace(1) %b, ptr addrspace(1) %af1 unordered, align 8
  store atomic i32 %x, ptr addrspace(1) %af2 unordered, align 4
  ; b: offset 8 = ref %a, offset 16 = int %y
  %bf1 = getelementptr inbounds i8, ptr addrspace(1) %b, i64 8
  %bf2 = getelementptr inbounds i8, ptr addrspace(1) %b, i64 16
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %bf1 unordered, align 8
  store atomic i32 %y, ptr addrspace(1) %bf2 unordered, align 4
  %va = load atomic i32, ptr addrspace(1) %af2 unordered, align 4
  %vb = load atomic i32, ptr addrspace(1) %bf2 unordered, align 4
  ; Both %a and %b are direct locals slots in the deopt bundle:
  ;   enc(LocalType, index=0, T_OBJECT) = 12, then %a
  ;   enc(LocalType, index=1, T_OBJECT) = (1<<32)|12 = 4294967308, then %b
  call void @sink(i32 %va, i32 %vb)
       [ "deopt"(i32 99, i32 99, i64 12, ptr addrspace(1) %a,
                 i64 4294967308, ptr addrspace(1) %b) ]
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; vo-ids: %a=0, %b=1. Roots are collected in bundle-operand order [%a, %b] and
; the closure worklist is LIFO, so %b is planned first (lower SeqNo) and applies
; first; %a applies second and its descriptor is inserted at the VO-section
; FRONT. Final emit order is therefore [desc_a, desc_b]. desc_a's VORef field
; points at desc_b (parsed LATER) — a FORWARD reference that exercises the
; HotSpot two-pass / deferred VORef-field resolution (end-to-end via jtreg).
; CHECK-LABEL: define void @cyclic_voref_fields
; CHECK-NOT: jeandle.new_instance
; CHECK: call void @sink(i32 %x, i32 %y)
; CHECK-SAME: [ "deopt"(
; CHECK-SAME: i32 99, i32 99,
; descriptor a header (vo_id=0, ScalarValueType, T_OBJECT): (0<<32)|(4<<16)|12 = 262156
; CHECK-SAME: i64 262156, i64 100, i32 2,
; a field 0 (offset 8, VORefLocalType/T_OBJECT): (8<<32)|(8<<16)|12 = 34360262668
;   -> value is the i32 vo-id of %b (1) — a FORWARD ref to desc_b below
; CHECK-SAME: i64 34360262668, i32 1,
; a field 1 (offset 16, LocalType/T_INT): (16<<32)|10 = 68719476746 -> value %x
; CHECK-SAME: i64 68719476746, i32 %x,
; descriptor b header (vo_id=1, ScalarValueType, T_OBJECT): (1<<32)|(4<<16)|12 = 4295229452
; CHECK-SAME: i64 4295229452, i64 200, i32 2,
; b field 0 (offset 8, VORefLocalType/T_OBJECT): (8<<32)|(8<<16)|12 = 34360262668
;   -> value is the i32 vo-id of %a (0) — backward ref to desc_a above
; CHECK-SAME: i64 34360262668, i32 0,
; b field 1 (offset 16, LocalType/T_INT): (16<<32)|10 = 68719476746 -> value %y
; CHECK-SAME: i64 68719476746, i32 %y,
; %a's locals slot (index 0) -> VORefLocalType(vo_id=0): (0<<32)|(8<<16)|12 = 524300
; CHECK-SAME: i64 524300, i32 0,
; %b's locals slot (index 1) -> VORefLocalType(vo_id=1): (1<<32)|(8<<16)|12 = 4295491596
; CHECK-SAME: i64 4295491596, i32 1) ]
; The eliminated OrigAllocs must not appear in the bundle.
; CHECK-NOT: addrspace(1) %a
; CHECK-NOT: addrspace(1) %b

!java-method-compilation = !{}
