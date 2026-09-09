; RUN: opt -disable-output -verify-each \
; RUN:   -passes="require<partial-escape-analysis>,partial-escape-transform" \
; RUN:   -jeandle-trace-pea %s 2>&1 | FileCheck %s --check-prefix=TRACE
; RUN: opt -S -verify-each \
; RUN:   -passes="require<partial-escape-analysis>,partial-escape-transform" \
; RUN:   %s | FileCheck %s --check-prefix=IR

; An inlined callee retains its own BasicLock slot.  Slot identity, allocation
; order, and address therefore cannot encode global lock depth.  The callee
; slot is deliberately allocated first; lexical CFG nesting still makes the
; caller lock depth zero and the callee lock depth one.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1) nounwind
declare hotspotcc void @jeandle.monitorenter_with_lightweight_lock(ptr addrspace(1), ptr) nounwind
declare hotspotcc void @jeandle.monitorexit_with_lightweight_lock(ptr addrspace(1), ptr) nounwind
declare void @sink(ptr addrspace(1)) nounwind

define void @inlined_callee_lock_depth(i1 %choose) gc "hotspotgc" {
entry:
  %callee.lock = alloca i64, align 8
  %caller.lock = alloca i64, align 8
  %caller = call hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 68101 to ptr), i32 16, i1 false)
  %callee = call hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 68102 to ptr), i32 16, i1 false)
  call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
      ptr addrspace(1) %caller, ptr %caller.lock)
  br i1 %choose, label %callee.left, label %callee.right
callee.left:
  call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
      ptr addrspace(1) %callee, ptr %callee.lock)
  call void @sink(ptr addrspace(1) %callee)
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
      ptr addrspace(1) %callee, ptr %callee.lock)
  br label %return
callee.right:
  call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
      ptr addrspace(1) %callee, ptr %callee.lock)
  call void @sink(ptr addrspace(1) %callee)
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
      ptr addrspace(1) %callee, ptr %callee.lock)
  br label %return
return:
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
      ptr addrspace(1) %caller, ptr %caller.lock)
  ret void
}

; TRACE: PEA: LockReplay function=@inlined_callee_lock_depth{{.*}}receiver_vo=[[CALLER:[0-9]+]] depth=0 ordinal=0
; TRACE-NEXT: PEA: LockReplay function=@inlined_callee_lock_depth{{.*}}receiver_vo=[[CALLEE:[0-9]+]] depth=1 ordinal=1
; TRACE-NEXT: PEA: LockReplay function=@inlined_callee_lock_depth{{.*}}receiver_vo=[[CALLER]] depth=0 ordinal=0
; TRACE-NEXT: PEA: LockReplay function=@inlined_callee_lock_depth{{.*}}receiver_vo=[[CALLEE]] depth=1 ordinal=1
; TRACE-NOT: function=@inlined_callee_lock_depth{{.*}} depth=2

; IR-LABEL: define void @inlined_callee_lock_depth(
; IR: callee.left:
; IR: call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(ptr addrspace(1) %caller, ptr %caller.lock)
; IR-NEXT: call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(ptr addrspace(1) %callee, ptr %callee.lock)
; IR-NEXT: call void @sink(ptr addrspace(1) %callee)
; IR: callee.right:
; IR: call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(ptr addrspace(1) %caller, ptr %caller.lock)
; IR-NEXT: call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(ptr addrspace(1) %callee, ptr %callee.lock)
; IR-NEXT: call void @sink(ptr addrspace(1) %callee)

!java-method-compilation = !{}
