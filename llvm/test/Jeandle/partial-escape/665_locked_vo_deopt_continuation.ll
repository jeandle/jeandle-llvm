; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; A locked virtual object at a DEOPT-CONTINUATION return (a `ret` reached
; via a deoptimize call). This is NOT a real function exit: execution
; continues in the interpreter with the frame state — including the
; eliminated lock — reconstructed from the deopt bundle. The commit-time
; unbalanced-lock gate must skip deopt-continuation blocks, or the VO is
; wrongly kept real and never described.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1), ptr) nounwind
declare i32 @__gxx_personality_v0(...)

define i32 @locked_vo_at_deopt_continuation(i32 %a) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %lock = alloca i64, align 8
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 24, i1 false)
       to label %n unwind label %u
n:
  %s1 = getelementptr inbounds i8, ptr addrspace(1) %o, i64 16
  store atomic i32 %a, ptr addrspace(1) %s1 unordered, align 4
  ; Folded monitorenter on the virtual receiver (lock elision). No matching
  ; exit on this path — the deopt bundle carries the lock instead.
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(
                  ptr addrspace(1) %o, ptr %lock)
  ; Deoptimize with the locked VO in the bundle: one locals entry
  ; (enc LocalType index=0 T_OBJECT = 12, %o) and one monitor entry
  ; (enc MonitorType index=0 T_OBJECT = 196620, object %o, basic_lock %lock).
  %r = call i32 (...) @llvm.experimental.deoptimize.i32(i32 -10)
       [ "deopt"(i32 99, i32 99,
                 i64 12, ptr addrspace(1) %o,
                 i64 196620, ptr addrspace(1) %o, ptr %lock) ]
  ret i32 %r
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

declare i32 @llvm.experimental.deoptimize.i32(...)

; The VO is described (ScalarValueType header 262156 = (0<<32)|(4<<16)|12)
; and eliminated; the monitor owner becomes a VORef with the eliminated
; marker (262156 = enc(index=1, MonitorType, T_OBJECT) is 65548 on the
; monitor line). No monitorenter survives.
; CHECK-LABEL: define i32 @locked_vo_at_deopt_continuation
; CHECK-NOT: jeandle.monitorenter
; CHECK-NOT: jeandle.new_instance
; CHECK: 262156

!java-method-compilation = !{}
