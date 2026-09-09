; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Preserve all operand bundles on the original allocation. Under the
; reuse-OrigAlloc model the ORIGINAL allocation invoke is kept verbatim, so
; every operand bundle it carries survives untouched — there is no
; bundle-copy step that could drop or reorder bundles. Here the allocation
; carries both a "deopt" and a "cfguardtarget" bundle; BOTH must remain on
; the retained invoke.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(ptr addrspace(1))
declare void @cfg_target_fn()
declare i32 @__gxx_personality_v0(...)

define void @multi_bundle() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       [ "deopt"(i32 7), "cfguardtarget"(ptr @cfg_target_fn) ]
       to label %n unwind label %u
n:
  call void @sink(ptr addrspace(1) %o)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; Both operand bundles must survive on the RETAINED original allocation
; invoke; no second materialization invoke is emitted.
; CHECK-LABEL: define void @multi_bundle
; CHECK: invoke hotspotcc ptr addrspace(1) @jeandle.new_instance{{.*}}[ "deopt"(i32 7), "cfguardtarget"(ptr @cfg_target_fn) ]
; CHECK-NOT: invoke hotspotcc{{.*}}@jeandle.new_instance
; CHECK: call void @sink(ptr addrspace(1) %o)

!java-method-compilation = !{}
