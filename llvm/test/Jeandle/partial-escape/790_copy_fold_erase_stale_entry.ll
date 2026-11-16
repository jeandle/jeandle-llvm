; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" -jeandle-vm-callback-log=%S/Inputs/790_copy_fold_erase_stale_entry.cblog %s | FileCheck %s

; Erase oracle: the destination has a stale stored entry at element 0, and
; the source window has NO entries (a never-stored array — Java default
; values). The copy must ERASE the stale destination entry (an absent source
; entry is the default, not "keep the old value"), and the source's missing
; outer FieldStates map exercises the pre-inserted source entry in the
; commit phase.

declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32, i1, i1)
declare void @jeandle.copy(ptr addrspace(1), i64, ptr addrspace(1), i64, i64, ptr, ptr, i64, i64)
declare i32 @__gxx_personality_v0(...)

define i32 @copy_fold_erase_stale() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %src = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
            ptr inttoptr (i64 12345 to ptr), i32 2, i32 24, i32 16, i32 1048576, i1 false, i1 false)
         to label %init unwind label %u
init:
  %dest = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
            ptr inttoptr (i64 12345 to ptr), i32 2, i32 24, i32 16, i32 1048576, i1 false, i1 false)
         to label %store_stale unwind label %u
store_stale:
  %db = getelementptr inbounds i8, ptr addrspace(1) %dest, i32 16
  %d0 = getelementptr inbounds i32, ptr addrspace(1) %db, i64 0
  %d1 = getelementptr inbounds i32, ptr addrspace(1) %db, i64 1
  store atomic i32 99, ptr addrspace(1) %d0 unordered, align 4
  br label %do_copy
do_copy:
  invoke void @jeandle.copy(ptr addrspace(1) %src, i64 0, ptr addrspace(1) %dest, i64 0, i64 2,
                            ptr null, ptr null, i64 2, i64 2)
      #0 [ "deopt"(i32 99, i32 99, i64 12, ptr addrspace(1) %src) ]
      to label %read unwind label %u
read:
  %v0 = load atomic i32, ptr addrspace(1) %d0 unordered, align 4
  %v1 = load atomic i32, ptr addrspace(1) %d1 unordered, align 4
  %r = add i32 %v0, %v1
  ret i32 %r
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

attributes #0 = { "jeandle.copy.kind"="arraycopy" "jeandle.copy.validated" }

; CHECK-LABEL: define i32 @copy_fold_erase_stale
; CHECK-NOT: jeandle.new_array
; CHECK-NOT: jeandle.copy
; CHECK-NOT: store atomic
; CHECK-NOT: load atomic
; The stale 99 is erased: both destination elements read as the default 0.
; CHECK: %r = add i32 0, 0
; CHECK: ret i32 %r

!java-method-compilation = !{}
