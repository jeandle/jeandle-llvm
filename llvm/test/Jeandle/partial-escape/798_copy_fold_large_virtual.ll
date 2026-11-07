; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" -jeandle-vm-callback-log=%S/Inputs/770_copy_fold_v2v_full.cblog %s | FileCheck %s

; Large virtual-to-virtual folds are not capped: the folded destination is a
; virtual array, so its length is already bounded by the array-virtualization
; cap. Both src and dest are virtual int[16] arrays. The arraycopy-kind pseudo
; call folds into the dest VO's field state (entry transfer), the call is
; deleted, both allocations never escape, and the downstream dest loads fold
; to the transferred constants.

declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32)
declare void @jeandle.copy(ptr addrspace(1), i64, ptr addrspace(1), i64, i64, ptr, ptr, i64, i64)
declare i32 @__gxx_personality_v0(...)

define i32 @copy_fold_large_virtual() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %src = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
            ptr inttoptr (i64 12345 to ptr), i32 16, i32 80, i32 16, i32 1048576)
         to label %init unwind label %u
init:
  %sb = getelementptr inbounds i8, ptr addrspace(1) %src, i32 16
  %s0 = getelementptr inbounds i32, ptr addrspace(1) %sb, i64 0
  %s1 = getelementptr inbounds i32, ptr addrspace(1) %sb, i64 1
  %s2 = getelementptr inbounds i32, ptr addrspace(1) %sb, i64 2
  %s3 = getelementptr inbounds i32, ptr addrspace(1) %sb, i64 3
  store atomic i32 10, ptr addrspace(1) %s0 unordered, align 4
  store atomic i32 20, ptr addrspace(1) %s1 unordered, align 4
  store atomic i32 30, ptr addrspace(1) %s2 unordered, align 4
  store atomic i32 40, ptr addrspace(1) %s3 unordered, align 4
  %dest = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
            ptr inttoptr (i64 12345 to ptr), i32 16, i32 80, i32 16, i32 1048576)
         to label %do_copy unwind label %u
do_copy:
  invoke void @jeandle.copy(ptr addrspace(1) %src, i64 0, ptr addrspace(1) %dest, i64 0, i64 16,
                            ptr null, ptr null, i64 16, i64 16)
      #0 [ "deopt"(i32 99, i32 99, i64 12, ptr addrspace(1) %src) ]
      to label %read unwind label %u
read:
  %db = getelementptr inbounds i8, ptr addrspace(1) %dest, i32 16
  %d0 = getelementptr inbounds i32, ptr addrspace(1) %db, i64 0
  %d1 = getelementptr inbounds i32, ptr addrspace(1) %db, i64 1
  %d2 = getelementptr inbounds i32, ptr addrspace(1) %db, i64 2
  %d3 = getelementptr inbounds i32, ptr addrspace(1) %db, i64 3
  %v0 = load atomic i32, ptr addrspace(1) %d0 unordered, align 4
  %v1 = load atomic i32, ptr addrspace(1) %d1 unordered, align 4
  %v2 = load atomic i32, ptr addrspace(1) %d2 unordered, align 4
  %v3 = load atomic i32, ptr addrspace(1) %d3 unordered, align 4
  %a1 = add i32 %v0, %v1
  %a2 = add i32 %a1, %v2
  %r = add i32 %a2, %v3
  ret i32 %r
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

attributes #0 = { "jeandle.copy.kind"="arraycopy" "jeandle.copy.validated" }

; CHECK-LABEL: define i32 @copy_fold_large_virtual
; CHECK-NOT: jeandle.new_array
; CHECK-NOT: jeandle.copy
; CHECK-NOT: store atomic
; CHECK-NOT: load atomic
; The dest loads fold to the transferred source constants.
; CHECK: %a1 = add i32 10, 20
; CHECK: %a2 = add i32 %a1, 30
; CHECK: %r = add i32 %a2, 40
; CHECK: ret i32 %r

!java-method-compilation = !{}
