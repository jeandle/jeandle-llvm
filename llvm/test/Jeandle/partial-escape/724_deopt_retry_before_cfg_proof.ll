; RUN: opt -S -verify-each \
; RUN:   -passes="require<partial-escape-analysis>,partial-escape-transform" \
; RUN:   -jeandle-vm-callback-log=%S/Inputs/231_value_based_check_value_based.cblog \
; RUN:   %s | FileCheck %s

; The first attempt folds %b.is.null and treats %null.path as dead.  Its final
; deopt root later exposes %b when %a's equality replacement is vetoed.  The
; deopt obligation must suppress %b virtualization and retry before accepting
; the provisional CFG proof, so the winning attempt retains both branch arms
; and the allocation that escapes only on %null.path.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare hotspotcc i1
    @jeandle.check_if_value_based(ptr addrspace(1))
declare hotspotcc void
    @jeandle.register_finalizer_if_needed(ptr addrspace(1))
declare void @safepoint()
declare void @escape(ptr addrspace(1))
declare void @observe(i1)
declare i32 @__gxx_personality_v0(...)

define void @deopt_retry_before_cfg_proof()
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 7777 to ptr), i32 16, i1 false)
      to label %alloc.b unwind label %unwind

alloc.b:
  %b = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 7777 to ptr), i32 16, i1 false)
      to label %alloc.path unwind label %unwind

alloc.path:
  %path.object = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 7777 to ptr), i32 16, i1 false)
      to label %dispatch unwind label %unwind

dispatch:
  %same = icmp eq ptr addrspace(1) %a, %b
  %b.is.null = icmp eq ptr addrspace(1) %b, null
  br i1 %b.is.null, label %null.path, label %nonnull.path

null.path:
  call void @escape(ptr addrspace(1) %path.object)
  br label %merge

nonnull.path:
  br label %merge

merge:
  call void @safepoint()
      [ "deopt"(i32 99, i32 99, i64 10, i1 %same) ]
  %is.value.based = call hotspotcc i1
      @jeandle.check_if_value_based(ptr addrspace(1) %a)
  call void @observe(i1 %is.value.based)
  ret void

unwind:
  %ex = landingpad i64 cleanup
  resume i64 %ex
}

; CHECK-LABEL: define void @deopt_retry_before_cfg_proof()
; CHECK-COUNT-3: invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK: %[[BNULL:[A-Za-z0-9._]+]] = icmp eq ptr addrspace(1) %b, null
; CHECK: br i1 %[[BNULL]], label %null.path, label %nonnull.path
; CHECK: null.path:
; CHECK: call void @escape(ptr addrspace(1) %path.object)
; CHECK: nonnull.path:
; CHECK: call void @safepoint()
; CHECK-NOT: poison

define void @different_safepoint_descriptor_is_not_enough()
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 7777 to ptr), i32 16, i1 false)
      to label %alloc.b unwind label %unwind

alloc.b:
  %b = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 7777 to ptr), i32 16, i1 false)
      to label %body unwind label %unwind

body:
  call void @safepoint()
      [ "deopt"(i32 99, i32 99, i64 12, ptr addrspace(1) %b) ]
  %same = icmp eq ptr addrspace(1) %a, %b
  call void @safepoint()
      [ "deopt"(i32 99, i32 99, i64 10, i1 %same) ]
  %is.value.based = call hotspotcc i1
      @jeandle.check_if_value_based(ptr addrspace(1) %a)
  call void @observe(i1 %is.value.based)
  ret void

unwind:
  %ex = landingpad i64 cleanup
  resume i64 %ex
}

; CHECK-LABEL: define void @different_safepoint_descriptor_is_not_enough()
; CHECK-COUNT-2: invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK: call void @safepoint()
; CHECK-SAME: ptr addrspace(1) %b
; CHECK: %[[SAME:[A-Za-z0-9._]+]] = icmp eq ptr addrspace(1) %a, %b
; CHECK: call void @safepoint()
; CHECK-SAME: i1 %[[SAME]]
; CHECK-NOT: poison

define void @deleted_safepoint_has_no_obligation()
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 7777 to ptr), i32 16, i1 false)
      to label %alloc.b unwind label %unwind

alloc.b:
  %b = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 7777 to ptr), i32 16, i1 false)
      to label %alloc.receiver unwind label %unwind

alloc.receiver:
  %receiver = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 7777 to ptr), i32 16, i1 false)
      to label %body unwind label %unwind

body:
  %same = icmp eq ptr addrspace(1) %a, %b
  call hotspotcc void @jeandle.register_finalizer_if_needed(
      ptr addrspace(1) %receiver)
      [ "deopt"(i32 99, i32 99, i64 10, i1 %same) ]
  %is.value.based = call hotspotcc i1
      @jeandle.check_if_value_based(ptr addrspace(1) %a)
  call void @observe(i1 %is.value.based)
  ret void

unwind:
  %ex = landingpad i64 cleanup
  resume i64 %ex
}

; CHECK-LABEL: define void @deleted_safepoint_has_no_obligation()
; The folded safepoint and its bundle disappear, so %b and %receiver remain
; eliminable; only value-based %a survives.
; CHECK-COUNT-1: invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK-NOT: jeandle.register_finalizer_if_needed
; CHECK-NOT: poison

define void @synthetic_dependency_suppresses_ordinary_leaves(i1 %pick)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 7777 to ptr), i32 16, i1 false)
      to label %choose unwind label %unwind

choose:
  br i1 %pick, label %left, label %right

left:
  %left.object = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 7777 to ptr), i32 16, i1 false)
      to label %merge unwind label %unwind

right:
  %right.object = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 7777 to ptr), i32 16, i1 false)
      to label %merge unwind label %unwind

merge:
  %object = phi ptr addrspace(1)
      [ %left.object, %left ], [ %right.object, %right ]
  %same = icmp eq ptr addrspace(1) %a, %object
  call void @safepoint()
      [ "deopt"(i32 99, i32 99, i64 10, i1 %same) ]
  %is.value.based = call hotspotcc i1
      @jeandle.check_if_value_based(ptr addrspace(1) %a)
  call void @observe(i1 %is.value.based)
  ret void

unwind:
  %ex = landingpad i64 cleanup
  resume i64 %ex
}

; CHECK-LABEL: define void @synthetic_dependency_suppresses_ordinary_leaves(
; CHECK-COUNT-3: invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK: %object = phi ptr addrspace(1)
; CHECK: %same = icmp eq ptr addrspace(1) %a, %object
; CHECK: call void @safepoint()
; CHECK-SAME: i1 %same
; CHECK-NOT: poison

!java-method-compilation = !{}
