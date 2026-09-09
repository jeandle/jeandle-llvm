; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Self-referential field (o.f = o) on the LIVE (single escape-point) path.
; Under reuse-OrigAlloc the single OrigAlloc is kept, the self-referential
; store replays onto OrigAlloc (%o into its own field), and the sink receives
; OrigAlloc directly. Regression guard that the live self-referential case
; stays correct with OrigAlloc as both the field-replay value and the escape
; argument (no <badref>, no additional allocation).

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @self_field_live_escape() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 12345 to ptr), i32 16, i1 false) to label %cont unwind label %u
cont:
  %slot = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  store atomic ptr addrspace(1) %o, ptr addrspace(1) %slot unordered, align 8
  call void @sink(ptr addrspace(1) %o)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

!java-method-compilation = !{}

; CHECK-LABEL: define void @self_field_live_escape
; Exactly one allocation invoke (the original OrigAlloc, retained).
; CHECK: invoke hotspotcc{{.*}}@jeandle.new_instance(ptr inttoptr (i64 12345 to ptr)
; CHECK-NOT: pea.mat = invoke
; The self-referential store uses the live OrigAlloc %o (no <badref>).
; CHECK: %[[SLOT:[A-Za-z0-9._]+]] = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
; CHECK: store atomic ptr addrspace(1) %o, ptr addrspace(1) %[[SLOT]] unordered, align 8
; The sink receives OrigAlloc directly (no new allocation invoke).
; CHECK: call void @sink(ptr addrspace(1) %o)
; CHECK: ret void
