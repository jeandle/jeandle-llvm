; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" -jeandle-vm-callback-log=%S/Inputs/791_clone_instance_fold.cblog %s | FileCheck %s

; clone-instance byte-payload fold, virtual-to-virtual: the payload window
; [16, 32) covers both int fields and the reference field; each field entry
; transfers from the source VO to the fresh clone VO (the reference stays a
; VirtualRef). A stale pre-clone store into the destination is erased by the
; full-coverage copy.

@instanceOopDesc.base_offset_in_bytes = constant i64 16

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @jeandle.copy(ptr addrspace(1), i64, ptr addrspace(1), i64, i64, ptr, ptr, i64, i64)
declare i32 @__gxx_personality_v0(...)

define i32 @clone_instance_fold() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %other = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 30002 to ptr), i32 16, i1 false)
         to label %init unwind label %u
init:
  %src = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 30001 to ptr), i32 32, i1 false)
         to label %stores unwind label %u
stores:
  %sx = getelementptr inbounds i8, ptr addrspace(1) %src, i64 16
  %sy = getelementptr inbounds i8, ptr addrspace(1) %src, i64 20
  %sr = getelementptr inbounds i8, ptr addrspace(1) %src, i64 24
  store atomic i32 7, ptr addrspace(1) %sx unordered, align 4
  store atomic i32 9, ptr addrspace(1) %sy unordered, align 4
  store atomic ptr addrspace(1) %other, ptr addrspace(1) %sr unordered, align 8
  %dst = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 30001 to ptr), i32 32, i1 false)
         to label %stale unwind label %u
stale:
  %dx0 = getelementptr inbounds i8, ptr addrspace(1) %dst, i64 16
  store atomic i32 99, ptr addrspace(1) %dx0 unordered, align 4
  br label %do_clone
do_clone:
  call void @jeandle.copy(ptr addrspace(1) %src, i64 16, ptr addrspace(1) %dst, i64 16,
                          i64 2, ptr null, ptr null, i64 32, i64 32)
      #0 [ "deopt"(i32 99, i32 99, i64 12, ptr addrspace(1) null) ]
  br label %read
read:
  %dx = getelementptr inbounds i8, ptr addrspace(1) %dst, i64 16
  %dy = getelementptr inbounds i8, ptr addrspace(1) %dst, i64 20
  %dr = getelementptr inbounds i8, ptr addrspace(1) %dst, i64 24
  %vx = load atomic i32, ptr addrspace(1) %dx unordered, align 4
  %vy = load atomic i32, ptr addrspace(1) %dy unordered, align 4
  %vr = load atomic ptr addrspace(1), ptr addrspace(1) %dr unordered, align 8
  %same = icmp eq ptr addrspace(1) %vr, %other
  %sel = select i1 %same, i32 1, i32 0
  %sum = add i32 %vx, %vy
  %r = add i32 %sum, %sel
  ret i32 %r
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

define i32 @clone_instance_fold_klass_window() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %other2 = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 30002 to ptr), i32 16, i1 false)
         to label %init2 unwind label %u2
init2:
  %src2 = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 30001 to ptr), i32 32, i1 false)
         to label %stores2 unwind label %u2
stores2:
  %sx2 = getelementptr inbounds i8, ptr addrspace(1) %src2, i64 16
  %sr2 = getelementptr inbounds i8, ptr addrspace(1) %src2, i64 24
  store atomic i32 7, ptr addrspace(1) %sx2 unordered, align 4
  store atomic ptr addrspace(1) %other2, ptr addrspace(1) %sr2 unordered, align 8
  %dst2 = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 30001 to ptr), i32 32, i1 false)
         to label %do_clone2 unwind label %u2
do_clone2:
  call void @jeandle.copy(ptr addrspace(1) %src2, i64 8, ptr addrspace(1) %dst2, i64 8,
                          i64 3, ptr null, ptr null, i64 32, i64 32)
      #0 [ "deopt"(i32 99, i32 99, i64 12, ptr addrspace(1) null) ]
  br label %read2
read2:
  %dx2 = getelementptr inbounds i8, ptr addrspace(1) %dst2, i64 16
  %dr2 = getelementptr inbounds i8, ptr addrspace(1) %dst2, i64 24
  %vx2 = load atomic i32, ptr addrspace(1) %dx2 unordered, align 4
  %vr2 = load atomic ptr addrspace(1), ptr addrspace(1) %dr2 unordered, align 8
  %same2 = icmp eq ptr addrspace(1) %vr2, %other2
  %sel2 = select i1 %same2, i32 1, i32 0
  %r2 = add i32 %vx2, %sel2
  ret i32 %r2
u2:
  %lp2 = landingpad i64 cleanup
  resume i64 %lp2
}

attributes #0 = { "jeandle.copy.kind"="clone-instance" "jeandle.copy.tightly-coupled-allocation" }

; CHECK-LABEL: define i32 @clone_instance_fold
; CHECK-NOT: jeandle.new_instance
; CHECK-NOT: jeandle.copy
; CHECK-NOT: store atomic
; CHECK-NOT: load atomic
; The stale 99 is erased by the full-coverage clone; the reference field
; keeps identity with %other (the comparison folds to true).
; CHECK: %sel = select i1 true, i32 1, i32 0
; CHECK: %sum = add i32 7, 9
; CHECK: %r = add i32 %sum, %sel
; CHECK: ret i32 %r

; The frontend-shaped window folds identically.
; CHECK-LABEL: define i32 @clone_instance_fold_klass_window
; CHECK-NOT: jeandle.new_instance
; CHECK-NOT: jeandle.copy
; CHECK-NOT: store atomic
; CHECK-NOT: load atomic
; CHECK: %sel2 = select i1 true, i32 1, i32 0
; CHECK: %r2 = add i32 7, %sel2
; CHECK: ret i32 %r2

!java-method-compilation = !{}
