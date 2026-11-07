; RUN: opt -S -verify-each \
; RUN:   -passes="require<partial-escape-analysis>,partial-escape-transform" \
; RUN:   -jeandle-vm-callback-log=%S/Inputs/802_clone_instance_fold_concrete.cblog \
; RUN:   %s | FileCheck %s

; clone-instance byte-payload fold over a CONCRETE source: the Jeandle
; counterpart of Graal ObjectClone's concrete-instance path (VirtualInstance-
; Node(type).getFields() -> one LoadFieldNode per field). The clone klass's
; non-static field list comes from the GetCloneInstanceInfo callback (the
; same enumeration CopySpecialization's instance-clone scalarization uses,
; queried without its expansion field-count bound);
; each field folds to an unordered-atomic semantic load placed at the call,
; and the destination VO stays virtual. A klass the callback declines
; (NotApplicable: injected fields or a non-leaf klass) keeps the
; bulk copy.

@instanceOopDesc.base_offset_in_bytes = constant i64 16

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @jeandle.copy(ptr addrspace(1), i64, ptr addrspace(1), i64, i64, ptr, ptr, i64, i64)
declare i32 @__gxx_personality_v0(...)

define i32 @clone_instance_concrete(
    ptr addrspace(1) "java-klass"="30001" "java-klass-exact" %src)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %dst = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 30001 to ptr), i32 32, i1 false)
         to label %do_clone unwind label %u
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
  %notnull = icmp ne ptr addrspace(1) %vr, null
  %sel = select i1 %notnull, i32 1, i32 0
  %sum = add i32 %vx, %vy
  %r = add i32 %sum, %sel
  ret i32 %r
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

define i32 @clone_instance_concrete_declined(
    ptr addrspace(1) "java-klass"="30005" "java-klass-exact" %src)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %dst = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 30005 to ptr), i32 32, i1 false)
         to label %do_clone unwind label %u
do_clone:
  call void @jeandle.copy(ptr addrspace(1) %src, i64 16, ptr addrspace(1) %dst, i64 16,
                          i64 2, ptr null, ptr null, i64 32, i64 32)
      #0 [ "deopt"(i32 99, i32 99, i64 12, ptr addrspace(1) null) ]
  br label %read
read:
  %dx = getelementptr inbounds i8, ptr addrspace(1) %dst, i64 16
  %vx = load atomic i32, ptr addrspace(1) %dx unordered, align 4
  ret i32 %vx
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; A ten-field class — beyond C2's ArrayCopyLoadStoreMaxElem bound that the
; callback applies to CopySpecialization's per-element expansion — still
; folds here: the PEA query carries field state and takes the complete
; layout (Graal's ObjectClone virtualize has no instance field-count bound).
define i32 @clone_instance_concrete_many_fields(
    ptr addrspace(1) "java-klass"="30007" "java-klass-exact" %src)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %dst = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 30007 to ptr), i32 56, i1 false)
         to label %do_clone unwind label %u
do_clone:
  call void @jeandle.copy(ptr addrspace(1) %src, i64 16, ptr addrspace(1) %dst, i64 16,
                          i64 5, ptr null, ptr null, i64 56, i64 56)
      #0 [ "deopt"(i32 99, i32 99, i64 12, ptr addrspace(1) null) ]
  br label %read
read:
  %dx = getelementptr inbounds i8, ptr addrspace(1) %dst, i64 16
  %dy = getelementptr inbounds i8, ptr addrspace(1) %dst, i64 52
  %vx = load atomic i32, ptr addrspace(1) %dx unordered, align 4
  %vy = load atomic i32, ptr addrspace(1) %dy unordered, align 4
  %sum = add i32 %vx, %vy
  ret i32 %sum
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; A boolean instance field occupies one JVM layout byte: the fold's storage
; mapping must read and carry it as i8 (the frontend's field-store width),
; not the i1 computational slot.
define i32 @clone_instance_concrete_boolean(
    ptr addrspace(1) "java-klass"="30009" "java-klass-exact" %src)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %dst = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 30009 to ptr), i32 24, i1 false)
         to label %do_clone unwind label %u
do_clone:
  call void @jeandle.copy(ptr addrspace(1) %src, i64 16, ptr addrspace(1) %dst, i64 16,
                          i64 1, ptr null, ptr null, i64 24, i64 24)
      #0 [ "deopt"(i32 99, i32 99, i64 12, ptr addrspace(1) null) ]
  br label %read
read:
  %dx = getelementptr inbounds i8, ptr addrspace(1) %dst, i64 16
  %vx = load atomic i8, ptr addrspace(1) %dx unordered, align 1
  %dy = getelementptr inbounds i8, ptr addrspace(1) %dst, i64 20
  %vy = load atomic i32, ptr addrspace(1) %dy unordered, align 4
  %zx = zext i8 %vx to i32
  %sum = add i32 %zx, %vy
  ret i32 %sum
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

attributes #0 = { "jeandle.copy.kind"="clone-instance" "jeandle.copy.tightly-coupled-allocation" }


; The destination never escapes: allocation and copy are both gone, and the
; three declared fields read through per-field semantic loads of the source.
; CHECK-LABEL: define i32 @clone_instance_concrete
; CHECK-NOT: jeandle.new_instance
; CHECK-NOT: jeandle.copy
; CHECK: %[[A0:.*]] = getelementptr inbounds i8, ptr addrspace(1) %src, i64 16
; CHECK: %[[L0:.*]] = load atomic i32, ptr addrspace(1) %[[A0]] unordered, align 4
; CHECK: %[[A1:.*]] = getelementptr inbounds i8, ptr addrspace(1) %src, i64 20
; CHECK: %[[L1:.*]] = load atomic i32, ptr addrspace(1) %[[A1]] unordered, align 4
; CHECK: %[[A2:.*]] = getelementptr inbounds i8, ptr addrspace(1) %src, i64 24
; CHECK: %[[L2:.*]] = load atomic ptr addrspace(1), ptr addrspace(1) %[[A2]] unordered, align 8
; The destination reads folded to the loaded values; nothing is stored.
; CHECK: %sum = add i32 %[[L0]], %[[L1]]
; CHECK: ret i32
; CHECK-NOT: store atomic
; CHECK-NOT: pea.mat

; A klass the callback declines keeps the bulk copy: the destination
; materializes at the call.
; CHECK-LABEL: define i32 @clone_instance_concrete_declined
; CHECK: jeandle.new_instance
; CHECK: call void @jeandle.copy
; CHECK: load atomic i32, ptr addrspace(1)
; CHECK: ret i32

; All ten fields fold — the count bound does not apply to the PEA query.
; CHECK-LABEL: define i32 @clone_instance_concrete_many_fields
; CHECK-NOT: jeandle.new_instance
; CHECK-NOT: jeandle.copy
; CHECK: %[[B0:.*]] = getelementptr inbounds i8, ptr addrspace(1) %src, i64 16
; CHECK: %[[M0:.*]] = load atomic i32, ptr addrspace(1) %[[B0]] unordered, align 4
; CHECK: %[[B9:.*]] = getelementptr inbounds i8, ptr addrspace(1) %src, i64 52
; CHECK: %[[M9:.*]] = load atomic i32, ptr addrspace(1) %[[B9]] unordered, align 4
; CHECK: %sum = add i32 %[[M0]], %[[M9]]
; CHECK: ret i32
; CHECK-NOT: store atomic


; The boolean field loads as one i8 byte; the int field as i32.
; CHECK-LABEL: define i32 @clone_instance_concrete_boolean
; CHECK-NOT: jeandle.new_instance
; CHECK-NOT: jeandle.copy
; CHECK: %[[C0:.*]] = getelementptr inbounds i8, ptr addrspace(1) %src, i64 16
; CHECK: %[[D0:.*]] = load atomic i8, ptr addrspace(1) %[[C0]] unordered, align 1
; CHECK: %[[C1:.*]] = getelementptr inbounds i8, ptr addrspace(1) %src, i64 20
; CHECK: %[[D1:.*]] = load atomic i32, ptr addrspace(1) %[[C1]] unordered, align 4
; CHECK: ret i32

!java-method-compilation = !{}
