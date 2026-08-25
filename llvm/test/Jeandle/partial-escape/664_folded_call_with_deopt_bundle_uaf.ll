; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; A folded JavaOp (balanced monitorenter/exit on virtual %b) whose
; monitorenter carries a deopt bundle referencing ANOTHER virtual object
; (%a). The fold records a ReplaceCallEffect and the bundle scan records a
; RewriteDeoptPoolEffect on the SAME call. The ordinary replacement erases the
; call first; the later pool rewrite must observe its nulled WeakTrackingVH and
; no-op instead of dereferencing freed memory. Not reachable from the current
; frontend (foldable JavaOps carry no deopt bundle), but legal IR that the
; transform must survive.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare hotspotcc void @jeandle.monitorenter_with_lightweight_lock(ptr addrspace(1), ptr) nounwind
declare hotspotcc void @jeandle.monitorexit_with_lightweight_lock(ptr addrspace(1), ptr) nounwind
declare void @sink(i32)
declare i32 @__gxx_personality_v0(...)

define void @rewrite_then_replace_uaf() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %lk = alloca i64, align 8
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 11111 to ptr), i32 24, i1 false)
       to label %na unwind label %u
na:
  %b = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 22222 to ptr), i32 24, i1 false)
       to label %nb unwind label %u
nb:
  call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
              ptr addrspace(1) %b, ptr %lk)
       [ "deopt"(i32 0, i32 0, i64 12, ptr addrspace(1) %a) ]
  call void @sink(i32 0)
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
              ptr addrspace(1) %b, ptr %lk)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; No crash; both objects are eliminated once the folded enter/exit die.
; CHECK-LABEL: define void @rewrite_then_replace_uaf
; CHECK-NOT: jeandle.monitorenter
; CHECK-NOT: jeandle.new_instance
; CHECK: call void @sink(i32 0)
; CHECK: ret void

!java-method-compilation = !{}
