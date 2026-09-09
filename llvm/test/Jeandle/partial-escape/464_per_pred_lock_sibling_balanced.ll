; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s -o %t
; RUN: FileCheck %s < %t
; RUN: not grep '!jeandle[.]pea[.]replay' %t

; `lockpath` holds a virtual monitor and branches to a mixed escape merge or
; to its matching exit. `alt` reaches the same escape merge without holding
; the monitor. Replay belongs only to lockpath->m1; the sibling m2 path keeps
; its virtual enter/exit pair eliminated. The held PHI routes only the replayed
; m1 path through the surviving real exit, keeping every input path balanced.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare hotspotcc void @jeandle.monitorenter_with_lightweight_lock(ptr addrspace(1), ptr) nounwind
declare hotspotcc void @jeandle.monitorexit_with_lightweight_lock(ptr addrspace(1), ptr) nounwind
declare void @sink(ptr addrspace(1))
declare void @marker()
declare i32 @__gxx_personality_v0(...)

define void @per_pred_lock_leak(i1 %c0, i1 %c1, ptr addrspace(1) %guard)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %lk = alloca i64, align 8
  %guard.lk = alloca i64, align 8
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 11111 to ptr), i32 24, i1 false)
       to label %n unwind label %u
n:
  br i1 %c0, label %lockpath, label %alt
lockpath:
  call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
              ptr addrspace(1) %o, ptr %lk)
  call void @marker()
  br i1 %c1, label %m1, label %m2
alt:
  call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
              ptr addrspace(1) %guard, ptr %guard.lk)
  br label %m1
m1:
  %held = phi i1 [ true, %lockpath ], [ false, %alt ]
  call void @sink(ptr addrspace(1) %o)
  br i1 %held, label %m1.exit, label %guard.exit
m1.exit:
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
              ptr addrspace(1) %o, ptr %lk)
  br label %done
guard.exit:
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
              ptr addrspace(1) %guard, ptr %guard.lk)
  br label %done
done:
  ret void
m2:
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
              ptr addrspace(1) %o, ptr %lk)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; Exactly one re-emitted enter executes on lockpath->m1 and exactly one real
; exit executes on the corresponding held arm. m2 contains neither operation.
; CHECK-LABEL: define void @per_pred_lock_leak(
; CHECK-NOT: pea.mat
; CHECK: lockpath:
; CHECK-NEXT: call void @marker()
; CHECK-NEXT: br i1 %c1, label %[[EDGE:[-A-Za-z$._0-9]+]], label %m2
; CHECK: [[EDGE]]:
; CHECK-NEXT: call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(ptr addrspace(1) %o, ptr %lk)
; CHECK-NEXT: br label %m1
; CHECK: m1:
; CHECK-NEXT: %held = phi i1 [ false, %alt ], [ true, %[[EDGE]] ]
; CHECK-NEXT: call void @sink(ptr addrspace(1) %o)
; CHECK-NEXT: br i1 %held, label %m1.exit, label %guard.exit
; CHECK: m1.exit:
; CHECK-NEXT: call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(ptr addrspace(1) %o, ptr %lk)
; CHECK-NEXT: br label %done
; CHECK: guard.exit:
; CHECK-NEXT: call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(ptr addrspace(1) %guard, ptr %guard.lk)
; CHECK-NEXT: br label %done
; CHECK: done:
; CHECK-NEXT: ret void
; CHECK: m2:
; CHECK-NOT: @jeandle.monitor
; CHECK-NEXT: ret void
; CHECK: u:
; CHECK-NOT: poison
; CHECK: }

!java-method-compilation = !{}
