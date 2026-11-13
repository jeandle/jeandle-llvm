; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" -jeandle-vm-callback-log=%S/Inputs/771_copy_fold_v2v_partial.cblog %s | FileCheck %s

; Virtual-to-virtual partial copy: src int[2] holds 11,22; dest int[4] is
; fresh. copy(src, 0, dest, 1, 2) transfers entries 11,22 into dest[1..2];
; dest[0] and dest[3] keep their default zero (absent field state on both
; sides), proving the copy does not touch elements outside [destPos,
; destPos+len).

declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32, i1, i1)
declare void @jeandle.copy(ptr addrspace(1), i64, ptr addrspace(1), i64, i64, ptr, ptr, i64, i64)
declare i32 @__gxx_personality_v0(...)

define i32 @copy_fold_v2v_partial() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %src = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
            ptr inttoptr (i64 12345 to ptr), i32 2, i32 24, i32 16, i32 1048576, i1 false, i1 false)
         to label %init unwind label %u
init:
  %sb = getelementptr inbounds i8, ptr addrspace(1) %src, i32 16
  %s0 = getelementptr inbounds i32, ptr addrspace(1) %sb, i64 0
  %s1 = getelementptr inbounds i32, ptr addrspace(1) %sb, i64 1
  store atomic i32 11, ptr addrspace(1) %s0 unordered, align 4
  store atomic i32 22, ptr addrspace(1) %s1 unordered, align 4
  %dest = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
            ptr inttoptr (i64 12345 to ptr), i32 4, i32 32, i32 16, i32 1048576, i1 false, i1 false)
         to label %do_copy unwind label %u
do_copy:
  invoke void @jeandle.copy(ptr addrspace(1) %src, i64 0, ptr addrspace(1) %dest, i64 1, i64 2,
                            ptr null, ptr null, i64 2, i64 4)
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

; CHECK-LABEL: define i32 @copy_fold_v2v_partial
; CHECK-NOT: jeandle.new_array
; CHECK-NOT: jeandle.copy
; CHECK-NOT: store atomic
; CHECK-NOT: load atomic
; dest[0] and dest[3] keep their default zero; dest[1..2] hold the
; transferred 11, 22.
; CHECK: %a1 = add i32 0, 11
; CHECK: %a2 = add i32 %a1, 22
; CHECK: %r = add i32 %a2, 0
; CHECK: ret i32 %r

!java-method-compilation = !{}
