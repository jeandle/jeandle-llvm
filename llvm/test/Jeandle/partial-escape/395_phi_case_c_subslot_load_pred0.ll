; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; PEA Case C — companion to 394 with the arms SWAPPED so the wide slot lives on
; the pred-0 (left) arm. Guards that predecessor ordering does not change the
; outcome.
;
;   left  (pred 0): stores i64 at offset 8   -> Fields {8 (8 bytes)}
;   right (pred 1): stores i32 at offset 24  -> Fields {24}
;
; Sub-width i32 load at offset 12 = high half of the i64 slot at offset 8.
; Sub-slot / narrowing loads are intentionally UNSUPPORTED, so the load bails:
; both objects materialize and the pointer PHI carries the two allocations —
; same conservative outcome as 394 regardless of which arm holds the wide
; slot.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @use(i32)
declare i32 @__gxx_personality_v0(...)

define void @test_casec_subslot_pred0(i1 %c)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  br i1 %c, label %left, label %right
left:
  %o1 = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 32, i1 false)
        to label %lstore unwind label %u
lstore:
  %l8 = getelementptr inbounds i8, ptr addrspace(1) %o1, i64 8
  store atomic i64 305419896, ptr addrspace(1) %l8 unordered, align 8
  br label %merge
right:
  %o2 = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 32, i1 false)
        to label %rstore unwind label %u
rstore:
  %r24 = getelementptr inbounds i8, ptr addrspace(1) %o2, i64 24
  store atomic i32 1, ptr addrspace(1) %r24 unordered, align 4
  br label %merge
merge:
  %p   = phi ptr addrspace(1) [ %o1, %lstore ], [ %o2, %rstore ]
  %s12 = getelementptr inbounds i8, ptr addrspace(1) %p, i64 12
  %v12 = load atomic i32, ptr addrspace(1) %s12 unordered, align 4
  call void @use(i32 %v12)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @test_casec_subslot_pred0
; Both objects materialize; sub-slot load is unsupported, so nothing folds.
; CHECK: invoke hotspotcc {{.*}}@jeandle.new_instance
; CHECK: invoke hotspotcc {{.*}}@jeandle.new_instance
; CHECK: phi ptr addrspace(1)
; CHECK: load atomic i32
; CHECK-NOT: pea.coerce
; CHECK: ret void

!java-method-compilation = !{}
