; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" -jeandle-vm-callback-log=%S/Inputs/777_copy_fold_bail_nonconst_len.cblog %s | FileCheck %s

; Non-constant length: the copy fold requires constant positions/length, so
; the pseudo call must survive and both arrays materialize at it (conservative
; generic-escape behavior, identical before and after the fold feature).

declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32, i1, i1)
declare void @jeandle.copy(ptr addrspace(1), i64, ptr addrspace(1), i64, i64, ptr, ptr, i64, i64)
declare i32 @__gxx_personality_v0(...)

define i32 @copy_fold_bail_nonconst_len(i32 %n) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %src = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
            ptr inttoptr (i64 12345 to ptr), i32 2, i32 24, i32 16, i32 1048576, i1 false, i1 false)
         to label %init unwind label %u
init:
  %sb = getelementptr inbounds i8, ptr addrspace(1) %src, i32 16
  %s0 = getelementptr inbounds i32, ptr addrspace(1) %sb, i64 0
  store atomic i32 11, ptr addrspace(1) %s0 unordered, align 4
  %dest = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
            ptr inttoptr (i64 12345 to ptr), i32 4, i32 32, i32 16, i32 1048576, i1 false, i1 false)
         to label %do_copy unwind label %u
do_copy:
  %nx = sext i32 %n to i64
  invoke void @jeandle.copy(ptr addrspace(1) %src, i64 0, ptr addrspace(1) %dest, i64 0, i64 %nx,
                            ptr null, ptr null, i64 2, i64 4)
      #0 [ "deopt"(i32 99, i32 99, i64 12, ptr addrspace(1) %src) ]
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

; CHECK-LABEL: define i32 @copy_fold_bail_nonconst_len
; CHECK: jeandle.new_array
; CHECK: invoke void @jeandle.copy
; CHECK: load atomic
; CHECK: ret i32

!java-method-compilation = !{}
