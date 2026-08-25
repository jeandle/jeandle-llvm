; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s
; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" -jeandle-pea-eliminate-locks=false %s | FileCheck %s --check-prefix=NOELIM

; PEA: monitorenter/monitorexit on a virtual receiver, balanced
; within a single block, are elided. The lock-count balance check in
; commit() guarantees we only elide when both sides are seen on the same
; virtual; unbalanced patterns flip the virtual to ineligible.
;
; Note: this test uses a simplified CFG with both enter and exit in the
; same block (no slow-path branches) because the analyzer enforces the
; single-block confinement rule for monitor folds.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1), ptr) nounwind
declare hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1), ptr) nounwind

declare i32 @__gxx_personality_v0(...)

define void @test_sync_simple() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %lock = alloca i64, align 8
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %n unwind label %u
n:
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(
                  ptr addrspace(1) %o, ptr %lock)
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(
                  ptr addrspace(1) %o, ptr %lock)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @test_sync_simple
; CHECK-NOT: jeandle.new_instance
; CHECK-NOT: jeandle.monitorenter_with_thin_lock
; CHECK-NOT: jeandle.monitorexit_with_thin_lock
; CHECK: ret void

!java-method-compilation = !{}

; NOELIM-LABEL: define void @test_sync_simple
; NOELIM: call hotspotcc void @jeandle.monitorenter_with_thin_lock
; NOELIM: call hotspotcc void @jeandle.monitorexit_with_thin_lock
