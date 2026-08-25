; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; CFG-depth guard: deep 3-level lexical nesting with the INNERMOST object
; escaping, no `!jeandle.lock_depth` metadata and no re-entrancy:
;   synchronized(a){ synchronized(b){ synchronized(c){ escape(c); } } }
; CFG dataflow assigns the three enters depths 0,1,2 (a, b, c in IR order).
; Escaping c (depth 2) fires the strict-lock cascade: a (outermost
; depth 0 < 2) and b (outermost depth 1 < 2) must also materialise at the
; same escape point so their re-emitted locks land below c's on the
; lightweight-lock thread lock stack. All three surviving (unbalanced) enters
; are merged and globally re-emitted ascending by CFG-derived depth: a, b, c.
;
; This is the non-re-entrant analogue of test 427 (which uses
; re-entrant interleaved locks) and exercises the full a->b->c cascade on the
; metadata-free path the frontend now produces.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare hotspotcc void @jeandle.monitorenter_with_lightweight_lock(ptr addrspace(1), ptr) nounwind
declare hotspotcc void @jeandle.monitorexit_with_lightweight_lock(ptr addrspace(1), ptr) nounwind
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @test_proxy_deep_nest_innermost_escape() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %la = alloca i64, align 8
  %lb = alloca i64, align 8
  %lc = alloca i64, align 8
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 11111 to ptr), i32 16, i1 false)
         to label %na unwind label %u
na:
  %b = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 22222 to ptr), i32 16, i1 false)
         to label %nb unwind label %u
nb:
  %c = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 33333 to ptr), i32 16, i1 false)
         to label %nc unwind label %u
nc:
  call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
                  ptr addrspace(1) %a, ptr %la)
  call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
                  ptr addrspace(1) %b, ptr %lb)
  call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
                  ptr addrspace(1) %c, ptr %lc)
  call void @sink(ptr addrspace(1) %c)
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
                  ptr addrspace(1) %c, ptr %lc)
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
                  ptr addrspace(1) %b, ptr %lb)
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
                  ptr addrspace(1) %a, ptr %la)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @test_proxy_deep_nest_innermost_escape
; All three objects materialise at the escape point; the re-emitted monitorenters
; appear strictly ascending by CFG-derived depth: a@0 (la), b@1 (lb), c@2 (lc).
; CHECK: monitorenter_with_lightweight_lock(ptr addrspace(1) %[[MATA:.*]], ptr %la)
; CHECK: monitorenter_with_lightweight_lock(ptr addrspace(1) %[[MATB:.*]], ptr %lb)
; CHECK: monitorenter_with_lightweight_lock(ptr addrspace(1) %[[MATC:.*]], ptr %lc)
; The sink sees the materialised c.
; CHECK: call void @sink(ptr addrspace(1) %[[MATC]])
; The three matching monitorexits survive, RAUW'd onto the materialised pointers.
; CHECK: monitorexit_with_lightweight_lock(ptr addrspace(1) %[[MATC]], ptr %lc)
; CHECK: monitorexit_with_lightweight_lock(ptr addrspace(1) %[[MATB]], ptr %lb)
; CHECK: monitorexit_with_lightweight_lock(ptr addrspace(1) %[[MATA]], ptr %la)
; CHECK: ret void

!java-method-compilation = !{}
