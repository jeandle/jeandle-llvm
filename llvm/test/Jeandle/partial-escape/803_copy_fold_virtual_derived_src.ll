; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" -jeandle-vm-callback-log=%S/Inputs/770_copy_fold_v2v_full.cblog -jeandle-dump-pea-stats %s 2>%t.stats | FileCheck %s
; RUN: FileCheck %s --check-prefix=STATS < %t.stats

; A copy source that is a DERIVED pointer of a still-virtual object (nonzero
; byte offset) must never fold: the element loads would read memory whose
; stores were eliminated and that is only written at materialization. The
; concrete-source leg enforces this explicitly (a resolveVirtualRef bail
; before any load is built), independent of the static-type gate — the same
; contract as the clone-instance concrete leg. With the whole object as the
; source this shape folds (see 773); the derived pointer is the only
; difference, so these functions pin the conservative contract.

target datalayout = "e-p:64:64"
declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32)
declare void @jeandle.copy(ptr addrspace(1), i64, ptr addrspace(1), i64, i64, ptr, ptr, i64, i64)
declare i32 @__gxx_personality_v0(...)

; STATS: PEA stats @derived_gep_src: {{.*}}CopyFolds=0
; CHECK-LABEL: define i32 @derived_gep_src(
; CHECK: @jeandle.new_array
; CHECK: @jeandle.new_array
; CHECK: @jeandle.copy
; CHECK: ret i32
define i32 @derived_gep_src() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %src = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
            ptr inttoptr (i64 12345 to ptr), i32 4, i32 32, i32 16, i32 1048576)
         to label %alloc unwind label %u
alloc:
  %dst = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
            ptr inttoptr (i64 12345 to ptr), i32 4, i32 32, i32 16, i32 1048576)
         to label %init unwind label %u
init:
  %s0 = getelementptr inbounds i8, ptr addrspace(1) %src, i64 16
  store atomic i32 11, ptr addrspace(1) %s0 unordered, align 4
  %derived = getelementptr inbounds i8, ptr addrspace(1) %src, i64 20
  invoke void @jeandle.copy(ptr addrspace(1) %derived, i64 0,
                            ptr addrspace(1) %dst, i64 0, i64 3,
                            ptr null, ptr null, i64 4, i64 4)
      #0 [ "deopt"(i32 99, i32 99, i64 12, ptr addrspace(1) null) ]
      to label %read unwind label %u
read:
  %d1 = getelementptr inbounds i8, ptr addrspace(1) %dst, i64 20
  %v1 = load atomic i32, ptr addrspace(1) %d1 unordered, align 4
  ret i32 %v1
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; STATS: PEA stats @derived_freeze_src: {{.*}}CopyFolds=0
; CHECK-LABEL: define i32 @derived_freeze_src(
; CHECK: @jeandle.new_array
; CHECK: @jeandle.new_array
; CHECK: @jeandle.copy
; CHECK: ret i32
define i32 @derived_freeze_src() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %src = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
            ptr inttoptr (i64 12345 to ptr), i32 4, i32 32, i32 16, i32 1048576)
         to label %alloc unwind label %u
alloc:
  %dst = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
            ptr inttoptr (i64 12345 to ptr), i32 4, i32 32, i32 16, i32 1048576)
         to label %init unwind label %u
init:
  %s0 = getelementptr inbounds i8, ptr addrspace(1) %src, i64 16
  store atomic i32 22, ptr addrspace(1) %s0 unordered, align 4
  %inner = getelementptr inbounds i8, ptr addrspace(1) %src, i64 20
  %derived = freeze ptr addrspace(1) %inner
  invoke void @jeandle.copy(ptr addrspace(1) %derived, i64 0,
                            ptr addrspace(1) %dst, i64 0, i64 3,
                            ptr null, ptr null, i64 4, i64 4)
      #0 [ "deopt"(i32 99, i32 99, i64 12, ptr addrspace(1) null) ]
      to label %read unwind label %u
read:
  %d1 = getelementptr inbounds i8, ptr addrspace(1) %dst, i64 20
  %v1 = load atomic i32, ptr addrspace(1) %d1 unordered, align 4
  ret i32 %v1
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

attributes #0 = { "jeandle.copy.kind"="arraycopy" "jeandle.copy.validated" }

!java-method-compilation = !{}
