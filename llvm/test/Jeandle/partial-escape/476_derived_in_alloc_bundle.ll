; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Derived-pointer VO reference inside an allocation invoke's deopt bundle:
; %g = gep(%a, 8) is a DERIVED bundle operand —
; undescribable, so recordDeoptBundleMappings records nothing and the
; allocation's own deopt path materializes %a at the %b invoke.
; Under reuse-OrigAlloc OrigAlloc dominates the
; pre-computed GEP, so the GEP and the bundle slot stay valid; %a tracks no
; stores, so there is nothing to replay and the IR is unchanged. Companion
; of 475 (describable case).

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @derived_in_alloc_bundle() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 100 to ptr), i32 16, i1 false)
       to label %n1 unwind label %u
n1:
  %g = getelementptr inbounds i8, ptr addrspace(1) %a, i64 8
  %b = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 200 to ptr), i32 16, i1 false)
       [ "deopt"(i32 99, i32 99, i64 12, ptr addrspace(1) %g) ]
       to label %n2 unwind label %u
n2:
  call void @sink(ptr addrspace(1) %b)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; %a materializes at the %b invoke (PartiallyEscapes; undescribable derived
; operand): its invoke, the GEP, and the bundle slot all survive verbatim.
; No descriptor, no poison.
; CHECK-LABEL: define void @derived_in_alloc_bundle(
; CHECK: %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK: %g = getelementptr inbounds i8, ptr addrspace(1) %a, i64 8
; CHECK: %b = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 200 to ptr), i32 16, i1 false) [ "deopt"(i32 99, i32 99, i64 12, ptr addrspace(1) %g) ]
; CHECK-NOT: poison

!java-method-compilation = !{}
