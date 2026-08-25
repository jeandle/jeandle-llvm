; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Loop-body partial escape of a LOCKED object: allocated before the loop,
; monitorenter/exit in the body, and the object escapes via @sink (case A).
; The lock must be captured/re-emitted at the materialization point (the lock
; model deletes the enter and re-emits it at materialize). Exactly one
; allocation, and the monitorenter survives (re-emitted at the materialize).

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1), ptr) nounwind
declare hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1), ptr) nounwind
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @test_locked_escape_in_loop(i32 %n) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %lock = alloca i64, align 8
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %prep unwind label %u
prep:
  br label %loop
loop:
  %i = phi i32 [ 0, %prep ], [ %i1, %body ]
  %c = icmp slt i32 %i, %n
  br i1 %c, label %body, label %exit
body:
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(
              ptr addrspace(1) %o, ptr %lock)
  call void @sink(ptr addrspace(1) %o)
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(
              ptr addrspace(1) %o, ptr %lock)
  %i1 = add i32 %i, 1
  br label %loop
exit:
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @test_locked_escape_in_loop
; CHECK: invoke hotspotcc{{.*}}@jeandle.new_instance(
; CHECK-NOT: jeandle.new_instance
; The monitorenter is re-emitted at the materialize point and the escape uses
; the single materialized pointer.
; CHECK: call hotspotcc void @jeandle.monitorenter_with_thin_lock(
; CHECK: call void @sink(ptr addrspace(1)

!java-method-compilation = !{}
