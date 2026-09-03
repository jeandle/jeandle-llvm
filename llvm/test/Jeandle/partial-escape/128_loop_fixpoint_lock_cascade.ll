; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Lock-elision inside a loop body that the fixpoint must handle. Each
; iteration enters and exits the monitor on the body-local obj. Without
; escape, the lock pair elides and the alloc disappears.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1), ptr) nounwind
declare hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1), ptr) nounwind
declare void @use(i32)
declare i32 @__gxx_personality_v0(...)

define void @test_lock_cascade(i32 %n) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %lock = alloca i64, align 8
  br label %loop
loop:
  %i = phi i32 [ 0, %entry ], [ %i1, %lk ]
  %c = icmp slt i32 %i, %n
  br i1 %c, label %body, label %exit
body:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 3333 to ptr), i32 16, i1 false)
       to label %lk unwind label %u
lk:
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(
              ptr addrspace(1) %o, ptr %lock)
  call void @use(i32 %i)
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

; CHECK-LABEL: define void @test_lock_cascade
; CHECK-NOT: jeandle.new_instance
; CHECK-NOT: jeandle.monitorenter_with_thin_lock
; CHECK-NOT: jeandle.monitorexit_with_thin_lock
; CHECK: call void @use

!java-method-compilation = !{}
