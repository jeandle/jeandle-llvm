; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Exception edge state splitting — the snapshotting mechanism MUST
; capture the full pre-invoke per-object state, not just the entries that
; the invoke ends up materializing. An invoke that materializes one
; virtual (VO_A) leaves UNRELATED virtuals (VO_B) untouched on the unwind
; path; the handler must still observe VO_B as virtual so the analyzer's
; field-state fold continues to work in the handler.
;
; This is also a soundness regression test: a buggy implementation that
; saved a snapshot keyed on "objects that changed at the invoke" (rather
; than the full per-object state) would drop VO_B's FieldStates / Virtuals
; entry on the unwind variant — the handler's folded load below would then
; fail to fold and VO_B would remain in IR.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define i32 @test_290() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 11111 to ptr), i32 16, i1 false)
       to label %n0 unwind label %u_a
n0:
  %b = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 22222 to ptr), i32 16, i1 false)
       to label %n1 unwind label %u_b
n1:
  ; Virtual store into VO_B at offset 16 — tracked in FieldStates.
  %b_slot = getelementptr inbounds i8, ptr addrspace(1) %b, i64 16
  store i32 99, ptr addrspace(1) %b_slot, align 4
  ; Escape VO_A through @sink. This invoke materializes VO_A. The handler
  ; inherits a pre-invoke snapshot whose Virtuals set still contains VO_B
  ; (and whose FieldStates still records the store above).
  invoke void @sink(ptr addrspace(1) %a)
       to label %nfinal unwind label %handler
nfinal:
  ret i32 0
handler:
  %lp = landingpad i64 cleanup
  ; Folded load from VO_B's tracked field — must fold to the stored 99.
  %b_slot2 = getelementptr inbounds i8, ptr addrspace(1) %b, i64 16
  %v = load i32, ptr addrspace(1) %b_slot2, align 4
  ret i32 %v
u_a:
  %lpa = landingpad i64 cleanup
  resume i64 %lpa
u_b:
  %lpb = landingpad i64 cleanup
  resume i64 %lpb
}

; VO_B's allocation (klass 22222) must be eliminated, because the handler
; folds its only load and no other use escapes the object.
; CHECK-LABEL: define i32 @test_290
; CHECK-NOT: jeandle.new_instance(ptr inttoptr (i64 22222 to ptr), i32 16)
; The folded load reaches the handler's return as the constant 99.
; CHECK: ret i32 99

!java-method-compilation = !{}
