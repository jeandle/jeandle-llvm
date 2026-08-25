; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s
; RUN: opt -disable-output -jeandle-trace-pea \
; RUN:   -passes="require<partial-escape-analysis>,partial-escape-transform" %s 2>&1 \
; RUN:   | FileCheck %s --check-prefix=TRACE

; Invoke-unwind lock re-emit vs the unwind-edge state split.
; A locked VO escapes at a TERMINATOR invoke `foo(o)`. The materialize is
; placed BEFORE the invoke, so the re-emitted monitorenter executes on BOTH
; the normal and unwind edges. The UnwindData patch records the VO as
; materialized (locks cleared — the re-emit already covers them) in the
; pre-invoke snapshot inherited by the unwind successor: the handler sees the
; real object, so its escape does not re-emit the same enter AGAIN (a double
; acquire with no matching exit on the unwind path), and each edge releases
; the single acquired monitor before its real exit.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare hotspotcc void @jeandle.monitorenter_with_lightweight_lock(ptr addrspace(1), ptr) nounwind
declare hotspotcc void @jeandle.monitorexit_with_lightweight_lock(ptr addrspace(1), ptr) nounwind
declare void @foo(ptr addrspace(1))
declare void @bar(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @invoke_escape(i1 %c) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %lo = alloca i64, align 8
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 11111 to ptr), i32 16, i1 false)
       to label %n unwind label %u
n:
  tail call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
              ptr addrspace(1) %o, ptr %lo)
  invoke void @foo(ptr addrspace(1) %o) to label %ok unwind label %handler
ok:
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
              ptr addrspace(1) %o, ptr %lo)
  ret void
handler:
  %lp = landingpad i64 cleanup
  ; o escapes in the handler too
  call void @bar(ptr addrspace(1) %o)
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
              ptr addrspace(1) %o, ptr %lo)
  resume i64 %lp
u:
  %lpr = landingpad i64 cleanup
  resume i64 %lpr
}

; Exactly ONE re-emitted enter (immediately before the invoke, covering both
; edges); the ok path's exit survives as a real exit; the handler's bar(o)
; gets NO second re-emit.
; CHECK-LABEL: define void @invoke_escape(
; CHECK-NOT: tail call hotspotcc void @jeandle.monitorenter_with_lightweight_lock
; CHECK: call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(ptr addrspace(1) %o, ptr %lo)
; CHECK-NEXT: invoke void @foo(ptr addrspace(1) %o)
; CHECK-NOT: monitorenter
; CHECK: call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(ptr addrspace(1) %o, ptr %lo)
; CHECK: handler:
; CHECK: call void @bar(ptr addrspace(1) %o)
; CHECK-NOT: monitorenter
; CHECK-NOT: poison
; TRACE: PEA: LockReplay function=@invoke_escape

!java-method-compilation = !{}
