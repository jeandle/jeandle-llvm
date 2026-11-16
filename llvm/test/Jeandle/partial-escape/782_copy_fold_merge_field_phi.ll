; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" -jeandle-vm-callback-log=%S/Inputs/782_copy_fold_merge_field_phi.cblog %s | FileCheck %s

; The copy executes on one arm of a diamond only. At the merge, dest[0] is
; the copied element load on the copy arm and the default zero on the other
; arm — the merge machinery builds a field PHI over both, the destination is
; eliminated, and the merged load folds to the PHI.

declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32, i1, i1)
declare void @jeandle.copy(ptr addrspace(1), i64, ptr addrspace(1), i64, i64, ptr, ptr, i64, i64)
declare i32 @__gxx_personality_v0(...)

define i32 @copy_fold_merge_field_phi(ptr addrspace(1) "java-klass"="12345" %src, i1 %c) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %dest = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
            ptr inttoptr (i64 12345 to ptr), i32 2, i32 24, i32 16, i32 1048576, i1 false, i1 false)
         to label %branch unwind label %u
branch:
  br i1 %c, label %docopy, label %join
docopy:
  invoke void @jeandle.copy(ptr addrspace(1) %src, i64 0, ptr addrspace(1) %dest, i64 0, i64 2,
                            ptr null, ptr null, i64 2, i64 2)
      #0 [ "deopt"(i32 99, i32 99, i64 12, ptr addrspace(1) null) ]
      to label %join unwind label %u
join:
  %db = getelementptr inbounds i8, ptr addrspace(1) %dest, i32 16
  %d0 = getelementptr inbounds i32, ptr addrspace(1) %db, i64 0
  %v0 = load atomic i32, ptr addrspace(1) %d0 unordered, align 4
  ret i32 %v0
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

attributes #0 = { "jeandle.copy.kind"="arraycopy" "jeandle.copy.validated" }

; CHECK-LABEL: define i32 @copy_fold_merge_field_phi
; CHECK-NOT: jeandle.new_array
; CHECK-NOT: jeandle.copy
; CHECK: %[[A0:.*]] = getelementptr inbounds i8, ptr addrspace(1) %src, i64 16
; CHECK: %[[L0:.*]] = load atomic i32, ptr addrspace(1) %[[A0]] unordered, align 4
; CHECK: %[[PHI:.*]] = phi i32 [ %[[L0]], %docopy ], [ 0, %branch ]
; CHECK: ret i32 %[[PHI]]

!java-method-compilation = !{}
