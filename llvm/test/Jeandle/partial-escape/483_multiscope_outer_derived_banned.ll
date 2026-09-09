; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Multi-scope descriptors, outer-scope DERIVED pointer still banned: the
; ROOT scope's locals slot holds %of = gep(%o, 8) — a DERIVED pointer, not
; an identity alias of the VO. The multi-scope descriptor support does NOT
; lift the derived-pointer ban (see 473_derived_gep_bundle_banned.ll for the
; single-scope case): the VO is kept real (PartiallyEscapes — materialized
; at the call), the outer-scope slot keeps the LIVE derived oop, and no
; descriptor / VORef is emitted.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(i32)
declare i32 @__gxx_personality_v0(...)

define void @multiscope_derived(i32 %x) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 100 to ptr), i32 16, i1 false)
       to label %n1 unwind label %u
n1:
  %of = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  store atomic i32 %x, ptr addrspace(1) %of unordered, align 4
  ; Two-scope bundle: ROOT scope (bci 5, preceded by its should_reexecute
  ; i64) local 0 is the DERIVED pointer %of;
  ; the INNERMOST scope (bci 9) has one i32 local. (i64 393233 = MethodType
  ; marker pair encoding: (6<<16)|T_METADATA(17).)
  call void @sink(i32 %x)
       [ "deopt"(i64 0, i32 5, i32 5, i64 12, ptr addrspace(1) %of,
                 i64 393233, i64 777,
                 i64 1, i32 9, i32 9, i64 10, i32 %x) ]
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; The derived bundle operand bans description: the OrigAlloc invoke, the GEP
; and the field store survive; the outer-scope slot keeps the live %of; NO
; ScalarValueType descriptor header (262156) and NO VORefLocalType slot
; (524300) anywhere; no poison.
; CHECK-LABEL: define void @multiscope_derived(
; CHECK: invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK: %of = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
; CHECK: store atomic i32 %x, ptr addrspace(1) %pea.matslot unordered, align 4
; CHECK: call void @sink(i32 %x) [ "deopt"(i64 0, i32 5, i32 5, i64 12, ptr addrspace(1) %of,
; CHECK-NOT: i64 262156
; CHECK-NOT: i64 524300
; CHECK-NOT: poison

!java-method-compilation = !{}
