; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" -jeandle-vm-callback-log=%S/Inputs/772_copy_fold_overlap_reverse.cblog %s | FileCheck %s

; Same-VO overlapping copy must transfer entries in REVERSE order: with
; copy(a, 0, a, 1, 3) and initial entries 1,2,3,4, forward-order transfer
; would propagate the overwritten value (result 1,1,1,1); reverse order gives
; the Java memmove semantics 1,1,2,3 (sum 7).

declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32, i1, i1)
declare void @jeandle.copy(ptr addrspace(1), i64, ptr addrspace(1), i64, i64, ptr, ptr, i64, i64)
declare i32 @__gxx_personality_v0(...)

define i32 @copy_fold_overlap_reverse() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
          ptr inttoptr (i64 12345 to ptr), i32 4, i32 32, i32 16, i32 1048576, i1 false, i1 false)
       to label %init unwind label %u
init:
  %b = getelementptr inbounds i8, ptr addrspace(1) %a, i32 16
  %p0 = getelementptr inbounds i32, ptr addrspace(1) %b, i64 0
  %p1 = getelementptr inbounds i32, ptr addrspace(1) %b, i64 1
  %p2 = getelementptr inbounds i32, ptr addrspace(1) %b, i64 2
  %p3 = getelementptr inbounds i32, ptr addrspace(1) %b, i64 3
  store atomic i32 1, ptr addrspace(1) %p0 unordered, align 4
  store atomic i32 2, ptr addrspace(1) %p1 unordered, align 4
  store atomic i32 3, ptr addrspace(1) %p2 unordered, align 4
  store atomic i32 4, ptr addrspace(1) %p3 unordered, align 4
  br label %do_copy
do_copy:
  invoke void @jeandle.copy(ptr addrspace(1) %a, i64 0, ptr addrspace(1) %a, i64 1, i64 3,
                            ptr null, ptr null, i64 4, i64 4)
      #0 [ "deopt"(i32 99, i32 99, i64 12, ptr addrspace(1) %a) ]
      to label %read unwind label %u
read:
  %v0 = load atomic i32, ptr addrspace(1) %p0 unordered, align 4
  %v1 = load atomic i32, ptr addrspace(1) %p1 unordered, align 4
  %v2 = load atomic i32, ptr addrspace(1) %p2 unordered, align 4
  %v3 = load atomic i32, ptr addrspace(1) %p3 unordered, align 4
  %a1 = add i32 %v0, %v1
  %a2 = add i32 %a1, %v2
  %r = add i32 %a2, %v3
  ret i32 %r
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

attributes #0 = { "jeandle.copy.kind"="arraycopy" "jeandle.copy.validated" }

; CHECK-LABEL: define i32 @copy_fold_overlap_reverse
; CHECK-NOT: jeandle.new_array
; CHECK-NOT: jeandle.copy
; CHECK-NOT: store atomic
; CHECK-NOT: load atomic
; Reverse-order transfer gives 1,1,2,3 (forward order would read the already
; overwritten entry and produce 1,1,1,1).
; CHECK: %a1 = add i32 1, 1
; CHECK: %a2 = add i32 %a1, 2
; CHECK: %r = add i32 %a2, 3
; CHECK: ret i32 %r

!java-method-compilation = !{}
