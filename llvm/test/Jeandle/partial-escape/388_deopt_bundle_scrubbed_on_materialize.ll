; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; A VO that is BOTH a real call argument AND a deopt-bundle operand of the
; same call is MATERIALIZED at the call — never described as virtual there.
; Jeandle materializes the call's real virtual inputs
; (materializeVirtualCallArgs) BEFORE recording the frame-state virtual
; mappings (recordDeoptBundleMappings). At a DURING-CALL deopt this preserves
; one Java identity: the caller's frame and the callee's frame both reference
; the real OrigAlloc object, so the callee's field writes are visible to the
; caller. Recording the bundle before materializing the call args would
; instead keep OrigAlloc + replay fields AND emit a VO descriptor at the same
; call — deopt would reallocate a NEW object for the caller while the callee
; continued with the real one (identity split).
;
; (The sibling 641_escape_via_call_arg_no_vo_descriptor.ll covers the
; contrasting case where the VO is undescribable for REFERENCE-field
; reasons; 640 covers a bundle-only VO that escapes LATER — that one is
; still described as virtual at the pre-escape safepoint.)

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @partial_escape_descriptor_at_safepoint(i32 %a, i32 %b) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 24, i1 false)
       to label %n unwind label %u
n:
  %s1 = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  %s2 = getelementptr inbounds i8, ptr addrspace(1) %o, i64 16
  store atomic i32 %a, ptr addrspace(1) %s1 unordered, align 4
  store atomic i32 %b, ptr addrspace(1) %s2 unordered, align 4
  ; %o escapes via the @sink argument AND is in the deopt bundle (a locals
  ; slot, enc(LocalType, index=0, T_OBJECT)=12). materializeVirtualCallArgs
  ; materializes %o at the call FIRST, so the bundle slot keeps the live
  ; OrigAlloc oop and NO descriptor is emitted for %o.
  call void @sink(ptr addrspace(1) %o)
       [ "deopt"(i32 99, i32 99, i64 12, ptr addrspace(1) %o) ]
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @partial_escape_descriptor_at_safepoint
; OrigAlloc is RETAINED (PartiallyEscapes — it escapes via @sink) and is the
; only allocation invoke.
; CHECK: invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK-NOT: pea.mat = invoke
; Tracked field stores are replayed onto OrigAlloc before the escape.
; CHECK: store atomic i32 %a, ptr addrspace(1) %pea.matslot unordered, align 4
; CHECK: store atomic i32 %b, ptr addrspace(1) %pea.matslot{{[0-9]*}} unordered, align 4
; The sink still receives OrigAlloc directly, and its deopt bundle operand
; stays as the LIVE OrigAlloc reference (one identity across a during-call
; deopt).
; CHECK: call void @sink(ptr addrspace(1) %o)
; CHECK-SAME: [ "deopt"(i32 99, i32 99, i64 12, ptr addrspace(1) %o) ]
; NO VO descriptor for %o (ScalarValueType header 262156 / VORefType 524300
; must not appear).
; CHECK-NOT: i64 262156
; CHECK-NOT: i64 524300
; CHECK-NOT: poison

!java-method-compilation = !{}
