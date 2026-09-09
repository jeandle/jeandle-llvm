; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; PEA: diamond CFG. The escape branch acquires the lock and passes the
; virtual to an opaque sink (escape with lock held); the hot branch acquires
; and releases the lock without escaping. The escape-branch monitorenter +
; monitorexit are retained on the materialized pointer; the hot-branch
; monitor pair is fully elided. The materialization is hoisted to the
; allocation's normal-dest so it dominates both successors.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1), ptr) nounwind
declare hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1), ptr) nounwind
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @test_partial_escape_with_lock(i1 %c) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %lock = alloca i64, align 8
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %n unwind label %u
n:
  br i1 %c, label %escape, label %hot

escape:
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(
                  ptr addrspace(1) %o, ptr %lock)
  call void @sink(ptr addrspace(1) %o)
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(
                  ptr addrspace(1) %o, ptr %lock)
  br label %merge

hot:
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(
                  ptr addrspace(1) %o, ptr %lock)
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(
                  ptr addrspace(1) %o, ptr %lock)
  br label %merge

merge:
  ret void

u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; The escape branch retains the monitor calls on the materialized pointer.
; CHECK-LABEL: define void @test_partial_escape_with_lock
; CHECK: %[[MAT:[A-Za-z0-9._]+]] = invoke hotspotcc{{.*}}ptr addrspace(1) @jeandle.new_instance
; CHECK: call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %[[MAT]],
; CHECK: call void @sink(ptr addrspace(1) %[[MAT]])
; CHECK: call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %[[MAT]],
; The hot branch should have no remaining monitor calls (both elided).
; CHECK-NOT: monitorenter
; CHECK-NOT: monitorexit

!java-method-compilation = !{}
