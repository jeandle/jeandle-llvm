; RUN: opt -disable-output -verify-each \
; RUN:   -passes="require<partial-escape-analysis>,partial-escape-transform" \
; RUN:   -jeandle-trace-pea %s 2>&1 | FileCheck %s --check-prefix=TRACE
; RUN: opt -S -verify-each \
; RUN:   -passes="require<partial-escape-analysis>,partial-escape-transform,instcombine,simplifycfg,require<partial-escape-analysis>,partial-escape-transform" \
; RUN:   %s -o %t
; RUN: FileCheck %s --check-prefix=IR < %t
; RUN: not grep '!jeandle[.]pea[.]replay' %t

; Lock depth is a property of a dynamic CFG path.  The mutually exclusive
; arms below each enter a,b,a from depth zero.  Both materialization batches
; must consequently replay depths 0,1,2; visiting one arm first must not make
; the other arm start at depth three.  The real lock after the merge is not a
; PEA lock and must remain intact across both PEA rounds and canonicalization.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1) nounwind
declare hotspotcc void @jeandle.monitorenter_with_lightweight_lock(ptr addrspace(1), ptr) nounwind
declare hotspotcc void @jeandle.monitorexit_with_lightweight_lock(ptr addrspace(1), ptr) nounwind
declare void @sink(ptr addrspace(1)) nounwind

define void @cfg_predecessor_replay(i1 %choose, ptr addrspace(1) %real)
    gc "hotspotgc" {
entry:
  %left.a0 = alloca i64, align 8
  %left.b1 = alloca i64, align 8
  %left.a2 = alloca i64, align 8
  %right.a0 = alloca i64, align 8
  %right.b1 = alloca i64, align 8
  %right.a2 = alloca i64, align 8
  %real.lock = alloca i64, align 8
  %a = call hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 68001 to ptr), i32 16, i1 false)
  %b = call hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 68002 to ptr), i32 16, i1 false)
  br i1 %choose, label %left, label %right

left:
  call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
      ptr addrspace(1) %a, ptr %left.a0)
  call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
      ptr addrspace(1) %b, ptr %left.b1)
  call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
      ptr addrspace(1) %a, ptr %left.a2)
  call void @sink(ptr addrspace(1) %b)
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
      ptr addrspace(1) %a, ptr %left.a2)
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
      ptr addrspace(1) %b, ptr %left.b1)
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
      ptr addrspace(1) %a, ptr %left.a0)
  br label %merge

right:
  call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
      ptr addrspace(1) %a, ptr %right.a0)
  call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
      ptr addrspace(1) %b, ptr %right.b1)
  call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
      ptr addrspace(1) %a, ptr %right.a2)
  call void @sink(ptr addrspace(1) %b)
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
      ptr addrspace(1) %a, ptr %right.a2)
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
      ptr addrspace(1) %b, ptr %right.b1)
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
      ptr addrspace(1) %a, ptr %right.a0)
  br label %merge

merge:
  call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
      ptr addrspace(1) %real, ptr %real.lock)
  call void @sink(ptr addrspace(1) %real)
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
      ptr addrspace(1) %real, ptr %real.lock)
  ret void
}

; The analyzer visits one arm first, but both physical replay batches have the
; same semantic depths and preserve the repeated a receiver at depths 0 and 2.
; TRACE-DAG: PEA: LockReplay function=@cfg_predecessor_replay{{.*}}receiver_vo=[[A:[0-9]+]] depth=0 ordinal=0
; TRACE-DAG: PEA: LockReplay function=@cfg_predecessor_replay{{.*}}receiver_vo=[[B:[0-9]+]] depth=1 ordinal=1
; TRACE-DAG: PEA: LockReplay function=@cfg_predecessor_replay{{.*}}receiver_vo=[[A]] depth=2 ordinal=2
; TRACE-DAG: PEA: LockReplay function=@cfg_predecessor_replay{{.*}}receiver_vo=[[A]] depth=0 ordinal=0
; TRACE-DAG: PEA: LockReplay function=@cfg_predecessor_replay{{.*}}receiver_vo=[[B]] depth=1 ordinal=1
; TRACE-DAG: PEA: LockReplay function=@cfg_predecessor_replay{{.*}}receiver_vo=[[A]] depth=2 ordinal=2
; TRACE-NOT: function=@cfg_predecessor_replay{{.*}} depth=3
; TRACE-NOT: function=@cfg_predecessor_replay{{.*}} depth=4
; TRACE-NOT: function=@cfg_predecessor_replay{{.*}} depth=5

; IR-LABEL: define void @cfg_predecessor_replay(
; IR: left:
; IR: call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(ptr addrspace(1) %a, ptr{{( nonnull)?}} %left.a0)
; IR-NEXT: call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(ptr addrspace(1) %b, ptr{{( nonnull)?}} %left.b1)
; IR-NEXT: call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(ptr addrspace(1) %a, ptr{{( nonnull)?}} %left.a2)
; IR: right:
; IR: call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(ptr addrspace(1) %a, ptr{{( nonnull)?}} %right.a0)
; IR-NEXT: call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(ptr addrspace(1) %b, ptr{{( nonnull)?}} %right.b1)
; IR-NEXT: call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(ptr addrspace(1) %a, ptr{{( nonnull)?}} %right.a2)
; IR: call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(ptr addrspace(1) %real, ptr{{( nonnull)?}} %real.lock)
; IR-NEXT: call void @sink(ptr addrspace(1) %real)
; IR-NEXT: call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(ptr addrspace(1) %real, ptr{{( nonnull)?}} %real.lock)

!java-method-compilation = !{}
