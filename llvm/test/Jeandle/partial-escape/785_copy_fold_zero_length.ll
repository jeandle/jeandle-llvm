; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" -jeandle-vm-callback-log=%S/Inputs/785_copy_fold_zero_length.cblog %s | FileCheck %s

; Zero-length copy: the fold degenerates to deleting the call (no entries to
; transfer). Source bounds and element compatibility are proven even for
; an empty copy, and the destination never escapes.

declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32, i1, i1)
declare void @jeandle.copy(ptr addrspace(1), i64, ptr addrspace(1), i64, i64, ptr, ptr, i64, i64)
declare i32 @__gxx_personality_v0(...)

define i32 @copy_fold_zero_length(ptr addrspace(1) "java-klass"="12345" %src) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %dest = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
            ptr inttoptr (i64 12345 to ptr), i32 2, i32 24, i32 16, i32 1048576, i1 false, i1 false)
         to label %do_copy unwind label %u
do_copy:
  invoke void @jeandle.copy(ptr addrspace(1) %src, i64 1, ptr addrspace(1) %dest, i64 1, i64 0,
                            ptr null, ptr null, i64 2, i64 2)
      #0 [ "deopt"(i32 99, i32 99, i64 12, ptr addrspace(1) null) ]
      to label %read unwind label %u
read:
  %db = getelementptr inbounds i8, ptr addrspace(1) %dest, i32 16
  %d0 = getelementptr inbounds i32, ptr addrspace(1) %db, i64 0
  %v0 = load atomic i32, ptr addrspace(1) %d0 unordered, align 4
  ret i32 %v0
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

attributes #0 = { "jeandle.copy.kind"="arraycopy" "jeandle.copy.validated" }

; CHECK-LABEL: define i32 @copy_fold_zero_length
; CHECK-NOT: jeandle.new_array
; CHECK-NOT: jeandle.copy
; No element loads are created for a zero-length copy; the destination load
; folds to the default zero.
; CHECK-NOT: load atomic
; CHECK: ret i32 0

!java-method-compilation = !{}
