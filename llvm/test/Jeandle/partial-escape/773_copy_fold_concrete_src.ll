; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" -jeandle-vm-callback-log=%S/Inputs/773_copy_fold_concrete_src.cblog %s | FileCheck %s

; Concrete-to-virtual fold: the source is a parameter int[] (statically typed
; via java-klass) whose length operand (arg7) is constant, and the destination
; is a fresh virtual int[4]. The copy folds to per-element unordered atomic
; loads placed at the call site (inheriting its control context); the
; destination's loads fold to those element loads and the destination never
; escapes.

declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32, i1, i1)
declare void @jeandle.copy(ptr addrspace(1), i64, ptr addrspace(1), i64, i64, ptr, ptr, i64, i64)
declare i32 @__gxx_personality_v0(...)

define i32 @copy_fold_concrete_src(ptr addrspace(1) "java-klass"="12345" %src) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %dest = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
            ptr inttoptr (i64 12345 to ptr), i32 4, i32 32, i32 16, i32 1048576, i1 false, i1 false)
         to label %do_copy unwind label %u
do_copy:
  invoke void @jeandle.copy(ptr addrspace(1) %src, i64 0, ptr addrspace(1) %dest, i64 0, i64 4,
                            ptr null, ptr null, i64 4, i64 4)
      #0 [ "deopt"(i32 99, i32 99, i64 12, ptr addrspace(1) null) ]
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

; CHECK-LABEL: define i32 @copy_fold_concrete_src
; The destination allocation and the pseudo call are gone.
; CHECK-NOT: jeandle.new_array
; CHECK-NOT: jeandle.copy
; Element loads at the call's position, one per copied element.
; CHECK: %[[A0:.*]] = getelementptr inbounds i8, ptr addrspace(1) %src, i64 16
; CHECK: %[[L0:.*]] = load atomic i32, ptr addrspace(1) %[[A0]] unordered, align 4
; CHECK: %[[A1:.*]] = getelementptr inbounds i8, ptr addrspace(1) %src, i64 20
; CHECK: %[[L1:.*]] = load atomic i32, ptr addrspace(1) %[[A1]] unordered, align 4
; CHECK: %[[A2:.*]] = getelementptr inbounds i8, ptr addrspace(1) %src, i64 24
; CHECK: %[[L2:.*]] = load atomic i32, ptr addrspace(1) %[[A2]] unordered, align 4
; CHECK: %[[A3:.*]] = getelementptr inbounds i8, ptr addrspace(1) %src, i64 28
; CHECK: %[[L3:.*]] = load atomic i32, ptr addrspace(1) %[[A3]] unordered, align 4
; CHECK: br label %read
; The destination's own loads folded to the element loads.
; CHECK: %a1 = add i32 %[[L0]], %[[L1]]
; CHECK: %a2 = add i32 %a1, %[[L2]]
; CHECK: %r = add i32 %a2, %[[L3]]
; CHECK: ret i32 %r

!java-method-compilation = !{}
