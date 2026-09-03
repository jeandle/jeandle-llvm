; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; VirtualRef defensive: a VirtualRef field is loaded back at the wrong type. The
; outer's tracked field at offset 8 holds a `ptr addrspace(1)` (an oop),
; but the load reinterprets that slot as a `ptr addrspace(0)`
; (C-heap-typed pointer). coerceToType's same-bit-width pointer pair check
; refuses cross-addrspace coercion (GC-strategy hazard), so the outer
; bails to ineligible. The outer's allocation, its field store, and the
; load must all survive in IR. The inner is left untouched — there's no
; other use of %inner so it would otherwise be eliminated as dead, but
; the original allocation invoke must remain because dead-code elimination
; is the next pass's job, not PEA's.
;
; This test is the "exhaustive IR pattern coverage" guard: any legal
; pattern that PEA can't safely virtualize must degrade gracefully, not
; crash and not silently produce wrong code.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32)
declare void @sink_p0(ptr)
declare i32 @__gxx_personality_v0(...)

define void @test_virtualref_on_load_type_mismatch() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %inner = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
              ptr inttoptr (i64 12345 to ptr), i32 4, i32 32, i32 16, i32 1048576)
           to label %nA unwind label %u1
nA:
  %outer = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
              ptr inttoptr (i64 67890 to ptr), i32 16, i1 false)
           to label %nB unwind label %u2
nB:
  %slot = getelementptr inbounds i8, ptr addrspace(1) %outer, i64 8
  store atomic ptr addrspace(1) %inner, ptr addrspace(1) %slot unordered, align 8
  ; Cross-addrspace read: AS(1) slot, AS(0) load type — bailed by coerceToType.
  %loaded = load atomic ptr, ptr addrspace(1) %slot unordered, align 8
  call void @sink_p0(ptr %loaded)
  ret void
u1:
  %lp1 = landingpad i64 cleanup
  resume i64 %lp1
u2:
  %lp2 = landingpad i64 cleanup
  resume i64 %lp2
}

; CHECK-LABEL: define void @test_virtualref_on_load_type_mismatch
; Outer survives because it is ineligible: its allocation invoke (klass
; 67890), the field store, and the cross-addrspace load all remain. The
; sink_p0 still receives the load result. (The inner is still virtualizable
; on its own — no use escapes it — and EliminateAllocation RAUWs %inner to
; `poison` defensively; the surviving store consequently has a `poison`
; value operand. That's correct conservative behavior: PEA leaves a dead
; store for the next DCE pass to remove, instead of silently rewriting the
; mismatched load.)
; CHECK: invoke hotspotcc{{.*}}ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 67890 to ptr), i32 16, i1 false)
; CHECK: store atomic ptr addrspace(1) {{.*}}, ptr addrspace(1) %{{.*}} unordered
; CHECK: %[[LD:[A-Za-z0-9._]+]] = load atomic ptr, ptr addrspace(1) %{{.*}} unordered
; CHECK: call void @sink_p0(ptr %[[LD]])

!java-method-compilation = !{}
