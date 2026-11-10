; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" -jeandle-vm-callback-log=%S/Inputs/789_copy_fold_then_real_monitorexit.cblog %s | FileCheck %s

; Copy fold combined with a surviving REAL monitor operation: the unbalanced
; monitorexit (no matching enter) invalidates the monitor-depth model, so the
; exit stays a real call and the destination materializes AT it. The copy
; itself stays folded (materialization is not ineligibility), and the field
; replay writes the copied element-load values into the real array before
; the lock release — the copied entries survive the escape under the real
; monitor's ordering.

declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32, i1, i1)
declare hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1), ptr) nounwind
declare void @jeandle.copy(ptr addrspace(1), i64, ptr addrspace(1), i64, i64, ptr, ptr, i64, i64)
declare i32 @__gxx_personality_v0(...)

define void @copy_fold_then_real_exit(ptr addrspace(1) "java-klass"="12345" %src) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %lock = alloca i64, align 8
  %dest = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
            ptr inttoptr (i64 12345 to ptr), i32 2, i32 24, i32 16, i32 1048576, i1 false, i1 false)
         to label %do_copy unwind label %u
do_copy:
  invoke void @jeandle.copy(ptr addrspace(1) %src, i64 0, ptr addrspace(1) %dest, i64 0, i64 2,
                            ptr null, ptr null, i64 2, i64 2)
      #0 [ "deopt"(i32 99, i32 99, i64 12, ptr addrspace(1) null) ]
      to label %unlockit unwind label %u
unlockit:
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %dest, ptr %lock)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

attributes #0 = { "jeandle.copy.kind"="arraycopy" "jeandle.copy.validated" }

; CHECK-LABEL: define void @copy_fold_then_real_exit
; The pseudo call is gone; the destination stays real for the real lock
; release.
; CHECK-NOT: jeandle.copy
; CHECK: jeandle.new_array
; CHECK: %[[A0:.*]] = getelementptr inbounds i8, ptr addrspace(1) %src, i64 16
; CHECK: %[[L0:.*]] = load atomic i32, ptr addrspace(1) %[[A0]] unordered, align 4
; CHECK: %[[A1:.*]] = getelementptr inbounds i8, ptr addrspace(1) %src, i64 20
; CHECK: %[[L1:.*]] = load atomic i32, ptr addrspace(1) %[[A1]] unordered, align 4
; The copied values are replayed into the real array before the release.
; CHECK: store atomic i32 %[[L0]], ptr addrspace(1) {{%.*}} unordered, align 4
; CHECK: store atomic i32 %[[L1]], ptr addrspace(1) {{%.*}} unordered, align 4
; CHECK: call hotspotcc void @jeandle.monitorexit_with_thin_lock
; CHECK-NOT: poison

!java-method-compilation = !{}
