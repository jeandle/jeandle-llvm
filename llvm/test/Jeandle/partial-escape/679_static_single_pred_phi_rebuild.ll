; RUN: opt -S -verify-each -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; A derived-pointer PHI in a genuinely single-predecessor block forces its
; virtual incoming through Case A.  That materialization changes the state at
; block entry, so the block body must be reprocessed from the updated edge
; view.  In particular, the second field store is a real write: the opaque
; reader receives the derived PHI, not a virtual-object alias, and must observe
; 41 rather than the value replayed by the incoming-edge materialization.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare i32 @read_i32(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define i32 @static_single_pred_phi_rebuild()
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
           ptr inttoptr (i64 67901 to ptr), i32 16, i1 false)
       to label %pred unwind label %unwind

pred:
  %slot = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  store atomic i32 19, ptr addrspace(1) %slot unordered, align 4
  br label %single

single:
  %derived = phi ptr addrspace(1) [ %slot, %pred ]
  store atomic i32 41, ptr addrspace(1) %slot unordered, align 4
  %observed = call i32 @read_i32(ptr addrspace(1) %derived)
  ret i32 %observed

unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define i32 @static_single_pred_phi_rebuild(
; CHECK: pred:
; CHECK: store atomic i32 19
; CHECK: single:
; CHECK: store atomic i32 41
; CHECK: %[[OBSERVED:.*]] = call i32 @read_i32
; CHECK: ret i32 %[[OBSERVED]]
; CHECK-NOT: poison

!java-method-compilation = !{}
