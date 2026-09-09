; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" \
; RUN:   %s -o %t.ir
; RUN: FileCheck %s < %t.ir
; RUN: sed -n '/^define ptr addrspace(1) @cyclic_with_locks_cascade/,/^}/p' %t.ir \
; RUN:   | grep -c '^  store atomic' | FileCheck %s --check-prefix=STORE-COUNT
; RUN: sed -n '/^define ptr addrspace(1) @cyclic_with_locks_cascade/,/^}/p' %t.ir \
; RUN:   | grep -c 'call hotspotcc void @jeandle.monitorenter_with_thin_lock' \
; RUN:   | FileCheck %s --check-prefix=ENTER-COUNT
; RUN: sed -n '/^define ptr addrspace(1) @cyclic_with_locks_cascade/,/^}/p' %t.ir \
; RUN:   | grep -c 'call hotspotcc void @jeandle.monitorexit_with_thin_lock' \
; RUN:   | FileCheck %s --check-prefix=EXIT-COUNT
; RUN: opt -disable-output -jeandle-trace-pea \
; RUN:   -passes="require<partial-escape-analysis>,partial-escape-transform" %s 2>&1 \
; RUN:   | FileCheck %s --check-prefix=TRACE

; Cyclic field graph (A.f = B, B.g = A) combined with a live monitor on A,
; under the reuse-OrigAlloc model. A lock-internal sink escapes the
; whole cascade; both objects stay PARTIALLY-ESCAPING. The ORIGINAL allocations
; (OrigAlloc %a and OrigAlloc %b) are both KEPT (no new allocation invoke is
; created).
; The virtually-tracked field stores are replayed onto the OrigAllocs at the
; single escape point (the return), and the surviving monitorenter stays in
; materialized receiver, after which the monitor is released before return.
; The replayed enter uses OrigAlloc %a — semantically equivalent to the
; materialize-commit lowering (field writes, then MonitorEnters).
; The back edge B.g = A resolves to OrigAlloc %a (no poison).

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1), ptr) nounwind
declare hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1), ptr) nounwind
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define ptr addrspace(1) @cyclic_with_locks_cascade()
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %lk1 = alloca i64, align 8
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 11111 to ptr), i32 16, i1 false) to label %na unwind label %u
na:
  %b = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 22222 to ptr), i32 16, i1 false) to label %nb unwind label %u
nb:
  %sa = getelementptr inbounds i8, ptr addrspace(1) %a, i64 8
  store atomic ptr addrspace(1) %b, ptr addrspace(1) %sa unordered, align 8
  %sb = getelementptr inbounds i8, ptr addrspace(1) %b, i64 8
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %sb unordered, align 8
  tail call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %a, ptr %lk1)
  call void @sink(ptr addrspace(1) %a)
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %a, ptr %lk1)
  ret ptr addrspace(1) %a
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

!java-method-compilation = !{}

; CHECK-LABEL: define ptr addrspace(1) @cyclic_with_locks_cascade
; CHECK: %[[LOCK:[A-Za-z0-9._]+]] = alloca i64, align 8
; Both ORIGINAL allocation invokes are RETAINED.
; CHECK: %[[A:[A-Za-z0-9._]+]] = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 11111 to ptr), i32 16, i1 false)
; CHECK: %[[B:[A-Za-z0-9._]+]] = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 22222 to ptr), i32 16, i1 false)
; Materialization emits no new allocation invoke.
; CHECK-NOT: pea.mat = invoke
; Both cyclic field stores are replayed onto OrigAllocs at the escape point,
; with each back edge resolving to the correct OrigAlloc (no poison).
; CHECK-DAG: %[[B_SLOT:[A-Za-z0-9._]+]] = getelementptr inbounds{{( nuw)?}} i8, ptr addrspace(1) %[[B]], i64 8
; CHECK-DAG: store atomic ptr addrspace(1) %[[A]], ptr addrspace(1) %[[B_SLOT]] unordered, align 8
; CHECK-DAG: %[[A_SLOT:[A-Za-z0-9._]+]] = getelementptr inbounds{{( nuw)?}} i8, ptr addrspace(1) %[[A]], i64 8
; CHECK-DAG: store atomic ptr addrspace(1) %[[B]], ptr addrspace(1) %[[A_SLOT]] unordered, align 8
; CHECK-NOT: poison
; The surviving monitorenter is the canonical bare replay on OrigAlloc %a.
; CHECK-NOT: tail call hotspotcc void @jeandle.monitorenter_with_thin_lock
; CHECK: call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %[[A]], ptr %[[LOCK]])
; CHECK: call void @sink(ptr addrspace(1) %[[A]])
; CHECK: call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %[[A]], ptr %[[LOCK]])
; CHECK: ret ptr addrspace(1) %[[A]]
; TRACE: PEA: LockReplay function=@cyclic_with_locks_cascade
; STORE-COUNT: {{^2$}}
; ENTER-COUNT: {{^1$}}
; EXIT-COUNT: {{^1$}}
