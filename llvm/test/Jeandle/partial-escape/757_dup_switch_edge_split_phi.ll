; RUN: opt -S -verify-each \
; RUN:   -passes="require<partial-escape-analysis>,partial-escape-transform" \
; RUN:   %s | FileCheck %s

; Duplicate switch edges into a merge that also needs an edge-local replay:
; the switch in %p reaches %merge through two successor slots (default and
; case 0). Splitting the critical edge (%p, %merge) for %a's Case-A
; materialization redirects BOTH duplicate edges onto the single new
; .pea.replay edge block, so %c's field PHI (which recorded one %p incoming
; per duplicate edge) must collapse its two %p slots into one replay-block
; slot — otherwise the PHI ends up with more incomings than %merge has
; predecessor edges.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @escape(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define i32 @dup_switch_edge_split_phi(i32 %sel)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 75701 to ptr), i32 24, i1 false)
      to label %setup unwind label %u

setup:
  %c = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 75702 to ptr), i32 24, i1 false)
      to label %p unwind label %u

p:
  %a.field = getelementptr inbounds i8, ptr addrspace(1) %a, i64 16
  store atomic i32 7, ptr addrspace(1) %a.field unordered, align 4
  %c.field.p = getelementptr inbounds i8, ptr addrspace(1) %c, i64 16
  store atomic i32 11, ptr addrspace(1) %c.field.p unordered, align 4
  switch i32 %sel, label %merge [
    i32 0, label %merge
    i32 1, label %qside
  ]

qside:
  %b = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 75703 to ptr), i32 24, i1 false)
      to label %qstore unwind label %u

qstore:
  %c.field.q = getelementptr inbounds i8, ptr addrspace(1) %c, i64 16
  store atomic i32 22, ptr addrspace(1) %c.field.q unordered, align 4
  call void @escape(ptr addrspace(1) %b)
  br label %merge

merge:
  %which = phi ptr addrspace(1) [ %a, %p ], [ %a, %p ], [ %b, %qstore ]
  %c.reload = getelementptr inbounds i8, ptr addrspace(1) %c, i64 16
  %fv = load atomic i32, ptr addrspace(1) %c.reload unordered, align 4
  %which.field = getelementptr inbounds i8, ptr addrspace(1) %which, i64 16
  %av = load atomic i32, ptr addrspace(1) %which.field unordered, align 4
  %sum = add i32 %fv, %av
  ret i32 %sum

u:
  %ex = landingpad i64 cleanup
  resume i64 %ex
}

; %c stays virtual: its field PHI at %merge must carry exactly one incoming
; for the split replay block and one for %qstore.
; CHECK-LABEL: define i32 @dup_switch_edge_split_phi(
; CHECK-NOT: i64 75702
; CHECK: merge:
; CHECK: %pea.field.phi{{[0-9]*}} = phi i32
; CHECK-SAME: [ 22, %qstore ]
; CHECK-SAME: [ 11, %{{[^,]*}} ]
; CHECK: ret i32
; CHECK-NOT: poison

!java-method-compilation = !{}
