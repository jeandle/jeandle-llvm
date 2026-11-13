; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" -jeandle-vm-callback-log=%S/Inputs/783_copy_fold_deopt_descriptor.cblog %s | FileCheck %s

; The copy folds and the destination's only escape is a later safepoint's
; deopt bundle. The safepoint's bundle must be rewritten to a VORef plus a
; descriptor whose array fields are the copied element-load values — the
; fold's field state feeds the deopt reconstruction graph.

declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32, i1, i1)
declare void @jeandle.copy(ptr addrspace(1), i64, ptr addrspace(1), i64, i64, ptr, ptr, i64, i64)
declare void @safepoint()
declare i32 @__gxx_personality_v0(...)

define void @copy_fold_deopt_descriptor(ptr addrspace(1) "java-klass"="12345" %src) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %dest = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
            ptr inttoptr (i64 12345 to ptr), i32 2, i32 24, i32 16, i32 1048576, i1 false, i1 false)
         to label %do_copy unwind label %u
do_copy:
  invoke void @jeandle.copy(ptr addrspace(1) %src, i64 0, ptr addrspace(1) %dest, i64 0, i64 2,
                            ptr null, ptr null, i64 2, i64 2)
      #0 [ "deopt"(i32 99, i32 99, i64 12, ptr addrspace(1) null) ]
      to label %sp unwind label %u
sp:
  call void @safepoint()
      [ "deopt"(i32 99, i32 99, i64 12, ptr addrspace(1) %dest) ]
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

attributes #0 = { "jeandle.copy.kind"="arraycopy" "jeandle.copy.validated" }

; CHECK-LABEL: define void @copy_fold_deopt_descriptor
; CHECK-NOT: jeandle.new_array
; CHECK-NOT: jeandle.copy
; CHECK: %[[A0:.*]] = getelementptr inbounds i8, ptr addrspace(1) %src, i64 16
; CHECK: %[[L0:.*]] = load atomic i32, ptr addrspace(1) %[[A0]] unordered, align 4
; CHECK: %[[A1:.*]] = getelementptr inbounds i8, ptr addrspace(1) %src, i64 20
; CHECK: %[[L1:.*]] = load atomic i32, ptr addrspace(1) %[[A1]] unordered, align 4
; The safepoint's bundle is rewritten to a descriptor referencing the copied
; element loads as the array's field values.
; CHECK: call void @safepoint() [ "deopt"(
; CHECK-SAME: i64 12345, i32 2,
; CHECK-SAME: %[[L0]],
; CHECK-SAME: %[[L1]],

!java-method-compilation = !{}
