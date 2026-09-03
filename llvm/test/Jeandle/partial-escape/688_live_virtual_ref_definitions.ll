; RUN: opt -S -verify-each \
; RUN:   -passes="require<partial-escape-analysis>,partial-escape-transform" \
; RUN:   -jeandle-vm-callback-log=%S/Inputs/688_live_virtual_ref_definitions.cblog \
; RUN:   %s | FileCheck %s

; A virtual-reference dependency is a property of the current field
; definition, not of every store that ever reached the analyzer.  Each
; function below makes the outer object ineligible with HotSpot's
; value-based-class check after overwriting the child reference.  The outer
; allocation and the live null store must remain, but the overwritten
; reference store and its unreachable child allocation must still disappear.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare hotspotcc i1 @jeandle.check_if_value_based(ptr addrspace(1))
declare void @use_bool(i1)
declare void @may_throw()
declare void @sink_owner(ptr addrspace(1))
declare void @observe_owner(ptr addrspace(1))
declare void @safepoint()
declare i32 @__gxx_personality_v0(...)

define void @same_block_overwrite() gc "hotspotgc"
    personality ptr @__gxx_personality_v0 {
entry:
  %child = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 68801 to ptr), i32 16, i1 false)
      to label %alloc.outer unwind label %unwind
alloc.outer:
  %outer = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 68802 to ptr), i32 24, i1 false)
      to label %body unwind label %unwind
body:
  %slot = getelementptr inbounds i8, ptr addrspace(1) %outer, i64 16
  store atomic ptr addrspace(1) %child, ptr addrspace(1) %slot unordered, align 8
  store atomic ptr addrspace(1) null, ptr addrspace(1) %slot unordered, align 8
  %is.vb = call hotspotcc i1 @jeandle.check_if_value_based(
      ptr addrspace(1) %outer)
  call void @use_bool(i1 %is.vb)
  ret void
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @same_block_overwrite(
; CHECK-NOT: inttoptr (i64 68801 to ptr)
; CHECK: inttoptr (i64 68802 to ptr)
; CHECK-NOT: store atomic ptr addrspace(1) %child
; CHECK: store atomic ptr addrspace(1) null
; CHECK: call hotspotcc i1 @jeandle.check_if_value_based

define void @diamond_overwrite(i1 %choose) gc "hotspotgc"
    personality ptr @__gxx_personality_v0 {
entry:
  %child = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 68811 to ptr), i32 16, i1 false)
      to label %alloc.outer unwind label %unwind
alloc.outer:
  %outer = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 68812 to ptr), i32 24, i1 false)
      to label %choose.block unwind label %unwind
choose.block:
  %slot = getelementptr inbounds i8, ptr addrspace(1) %outer, i64 16
  br i1 %choose, label %left, label %right
left:
  store atomic ptr addrspace(1) %child, ptr addrspace(1) %slot unordered, align 8
  br label %merge
right:
  store atomic ptr addrspace(1) %child, ptr addrspace(1) %slot unordered, align 8
  br label %merge
merge:
  store atomic ptr addrspace(1) null, ptr addrspace(1) %slot unordered, align 8
  %is.vb = call hotspotcc i1 @jeandle.check_if_value_based(
      ptr addrspace(1) %outer)
  call void @use_bool(i1 %is.vb)
  ret void
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @diamond_overwrite(
; CHECK-NOT: inttoptr (i64 68811 to ptr)
; CHECK: inttoptr (i64 68812 to ptr)
; CHECK-NOT: store atomic ptr addrspace(1) %child
; CHECK: store atomic ptr addrspace(1) null
; CHECK: call hotspotcc i1 @jeandle.check_if_value_based

define void @loop_overwrite(i32 %count) gc "hotspotgc"
    personality ptr @__gxx_personality_v0 {
entry:
  %child = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 68821 to ptr), i32 16, i1 false)
      to label %alloc.outer unwind label %unwind
alloc.outer:
  %outer = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 68822 to ptr), i32 24, i1 false)
      to label %preheader unwind label %unwind
preheader:
  %slot = getelementptr inbounds i8, ptr addrspace(1) %outer, i64 16
  br label %header
header:
  %i = phi i32 [ 0, %preheader ], [ %next, %body ]
  %more = icmp slt i32 %i, %count
  br i1 %more, label %body, label %exit
body:
  store atomic ptr addrspace(1) %child, ptr addrspace(1) %slot unordered, align 8
  store atomic ptr addrspace(1) null, ptr addrspace(1) %slot unordered, align 8
  %next = add nuw i32 %i, 1
  br label %header
exit:
  %is.vb = call hotspotcc i1 @jeandle.check_if_value_based(
      ptr addrspace(1) %outer)
  call void @use_bool(i1 %is.vb)
  ret void
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @loop_overwrite(
; CHECK-NOT: inttoptr (i64 68821 to ptr)
; CHECK: inttoptr (i64 68822 to ptr)
; CHECK-NOT: store atomic ptr addrspace(1) %child
; CHECK: store atomic ptr addrspace(1) null
; CHECK: call hotspotcc i1 @jeandle.check_if_value_based

define void @nested_overwrite() gc "hotspotgc"
    personality ptr @__gxx_personality_v0 {
entry:
  %leaf = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 68831 to ptr), i32 16, i1 false)
      to label %alloc.middle unwind label %unwind
alloc.middle:
  %middle = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 68832 to ptr), i32 24, i1 false)
      to label %alloc.outer unwind label %unwind
alloc.outer:
  %outer = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 68833 to ptr), i32 24, i1 false)
      to label %body unwind label %unwind
body:
  %middle.slot = getelementptr inbounds i8, ptr addrspace(1) %middle, i64 16
  store atomic ptr addrspace(1) %leaf, ptr addrspace(1) %middle.slot unordered, align 8
  %outer.slot = getelementptr inbounds i8, ptr addrspace(1) %outer, i64 16
  store atomic ptr addrspace(1) %middle, ptr addrspace(1) %outer.slot unordered, align 8
  store atomic ptr addrspace(1) null, ptr addrspace(1) %outer.slot unordered, align 8
  %is.vb = call hotspotcc i1 @jeandle.check_if_value_based(
      ptr addrspace(1) %outer)
  call void @use_bool(i1 %is.vb)
  ret void
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @nested_overwrite(
; CHECK-NOT: inttoptr (i64 68831 to ptr)
; CHECK-NOT: inttoptr (i64 68832 to ptr)
; CHECK: inttoptr (i64 68833 to ptr)
; CHECK-NOT: store atomic ptr addrspace(1) %leaf
; CHECK-NOT: store atomic ptr addrspace(1) %middle
; CHECK: store atomic ptr addrspace(1) null
; CHECK: call hotspotcc i1 @jeandle.check_if_value_based

define void @deopt_observes_pre_overwrite_definition() gc "hotspotgc"
    personality ptr @__gxx_personality_v0 {
entry:
  %child = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 68841 to ptr), i32 16, i1 false)
      to label %alloc.outer unwind label %unwind
alloc.outer:
  %outer = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 68842 to ptr), i32 24, i1 false)
      to label %body unwind label %unwind
body:
  %slot = getelementptr inbounds i8, ptr addrspace(1) %outer, i64 16
  store atomic ptr addrspace(1) %child, ptr addrspace(1) %slot unordered, align 8
  call void @safepoint()
      [ "deopt"(i32 41, i32 41, i64 12, ptr addrspace(1) %outer) ]
  store atomic ptr addrspace(1) null, ptr addrspace(1) %slot unordered, align 8
  %is.vb = call hotspotcc i1 @jeandle.check_if_value_based(
      ptr addrspace(1) %outer)
  call void @use_bool(i1 %is.vb)
  ret void
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; The earlier safepoint observes outer.child, so abandoning the outer
; descriptor must retain both original allocations and the reaching store.
; CHECK-LABEL: define void @deopt_observes_pre_overwrite_definition(
; CHECK: inttoptr (i64 68841 to ptr)
; CHECK: inttoptr (i64 68842 to ptr)
; CHECK: store atomic ptr addrspace(1) %child
; CHECK: call void @safepoint() [ "deopt"(i32 41, i32 41, i64 12, ptr addrspace(1) %outer) ]
; CHECK-NOT: i64 524300
; CHECK: store atomic ptr addrspace(1) null

define void @invoke_paths_after_overwrite() gc "hotspotgc"
    personality ptr @__gxx_personality_v0 {
entry:
  %child = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 68851 to ptr), i32 16, i1 false)
      to label %alloc.outer unwind label %alloc.unwind
alloc.outer:
  %outer = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 68852 to ptr), i32 24, i1 false)
      to label %body unwind label %alloc.unwind
body:
  %slot = getelementptr inbounds i8, ptr addrspace(1) %outer, i64 16
  store atomic ptr addrspace(1) %child, ptr addrspace(1) %slot unordered, align 8
  store atomic ptr addrspace(1) null, ptr addrspace(1) %slot unordered, align 8
  %is.vb = call hotspotcc i1 @jeandle.check_if_value_based(
      ptr addrspace(1) %outer)
  call void @use_bool(i1 %is.vb)
  invoke void @may_throw() to label %normal unwind label %handler
normal:
  ret void
handler:
  %lp = landingpad i64 cleanup
  resume i64 %lp
alloc.unwind:
  %alloc.lp = landingpad i64 cleanup
  resume i64 %alloc.lp
}

; CHECK-LABEL: define void @invoke_paths_after_overwrite(
; CHECK-NOT: inttoptr (i64 68851 to ptr)
; CHECK: inttoptr (i64 68852 to ptr)
; CHECK-NOT: store atomic ptr addrspace(1) %child
; CHECK: store atomic ptr addrspace(1) null
; CHECK: invoke void @may_throw()
; CHECK: handler:
; CHECK: landingpad i64

define void @critical_edge_overwrite(i1 %take.source, i1 %early)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %child = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 68861 to ptr), i32 16, i1 false)
      to label %alloc.outer unwind label %unwind
alloc.outer:
  %outer = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 68862 to ptr), i32 24, i1 false)
      to label %choose unwind label %unwind
choose:
  %slot = getelementptr inbounds i8, ptr addrspace(1) %outer, i64 16
  br i1 %take.source, label %source, label %right
source:
  store atomic ptr addrspace(1) %child, ptr addrspace(1) %slot unordered, align 8
  br i1 %early, label %early.exit, label %merge
right:
  store atomic ptr addrspace(1) %child, ptr addrspace(1) %slot unordered, align 8
  br label %merge
merge:
  store atomic ptr addrspace(1) null, ptr addrspace(1) %slot unordered, align 8
  %is.vb = call hotspotcc i1 @jeandle.check_if_value_based(
      ptr addrspace(1) %outer)
  call void @use_bool(i1 %is.vb)
  ret void
early.exit:
  ret void
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @critical_edge_overwrite(
; CHECK-NOT: inttoptr (i64 68861 to ptr)
; CHECK: inttoptr (i64 68862 to ptr)
; CHECK-NOT: store atomic ptr addrspace(1) %child
; CHECK: store atomic ptr addrspace(1) null
; CHECK: call hotspotcc i1 @jeandle.check_if_value_based
; CHECK: early.exit:
; CHECK-NEXT: ret void

; At the merge, the left child definition is live while the right child store
; is dead behind a null overwrite.  Falling the owner back to real must retain
; the left definition and the right null without resurrecting the right child
; store.
define void @diamond_mixed_live_and_dead(i1 %choose) gc "hotspotgc"
    personality ptr @__gxx_personality_v0 {
entry:
  %child = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 68871 to ptr), i32 16, i1 false)
      to label %alloc.outer unwind label %unwind
alloc.outer:
  %outer = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 68872 to ptr), i32 24, i1 false)
      to label %choose.block unwind label %unwind
choose.block:
  %slot = getelementptr inbounds i8, ptr addrspace(1) %outer, i64 16
  br i1 %choose, label %left, label %right
left:
  store atomic ptr addrspace(1) %child, ptr addrspace(1) %slot unordered, align 8
  br label %merge
right:
  store atomic ptr addrspace(1) %child, ptr addrspace(1) %slot unordered, align 8
  store atomic ptr addrspace(1) null, ptr addrspace(1) %slot unordered, align 8
  br label %merge
merge:
  %is.vb = call hotspotcc i1 @jeandle.check_if_value_based(
      ptr addrspace(1) %outer)
  call void @use_bool(i1 %is.vb)
  ret void
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @diamond_mixed_live_and_dead(
; CHECK-COUNT-1: inttoptr (i64 68871 to ptr)
; CHECK-COUNT-1: inttoptr (i64 68872 to ptr)
; CHECK-COUNT-1: store atomic ptr addrspace(1) %child
; CHECK-COUNT-1: store atomic ptr addrspace(1) null
; CHECK: call hotspotcc i1 @jeandle.check_if_value_based

; The pointer PHI synthesizes a Case-C owner.  Its child definition is
; overwritten before the synthetic owner escapes, so the child allocation and
; historical store remain dead even though both real source owners survive.
define void @casec_owner_overwritten(i1 %choose) gc "hotspotgc"
    personality ptr @__gxx_personality_v0 {
entry:
  %child = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 68881 to ptr), i32 16, i1 false)
      to label %choose.block unwind label %unwind
choose.block:
  br i1 %choose, label %left, label %right
left:
  %left.owner = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 68882 to ptr), i32 24, i1 false)
      to label %left.cont unwind label %unwind
left.cont:
  br label %merge
right:
  %right.owner = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 68882 to ptr), i32 24, i1 false)
      to label %right.cont unwind label %unwind
right.cont:
  br label %merge
merge:
  %owner = phi ptr addrspace(1) [ %left.owner, %left.cont ],
                                     [ %right.owner, %right.cont ]
  %slot = getelementptr inbounds i8, ptr addrspace(1) %owner, i64 16
  store atomic ptr addrspace(1) %child, ptr addrspace(1) %slot unordered, align 8
  store atomic ptr addrspace(1) null, ptr addrspace(1) %slot unordered, align 8
  call void @sink_owner(ptr addrspace(1) %owner)
  ret void
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @casec_owner_overwritten(
; CHECK-NOT: inttoptr (i64 68881 to ptr)
; CHECK-COUNT-2: inttoptr (i64 68882 to ptr)
; CHECK-NOT: store atomic ptr addrspace(1) %child
; CHECK: store atomic ptr addrspace(1) null
; CHECK: call void @sink_owner

; The companion Case-C owner escapes with its child definition still current.
; Both source owners and the referenced child must stay real, and the live
; store must be restored.
define void @casec_owner_live(i1 %choose) gc "hotspotgc"
    personality ptr @__gxx_personality_v0 {
entry:
  %child = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 68891 to ptr), i32 16, i1 false)
      to label %choose.block unwind label %unwind
choose.block:
  br i1 %choose, label %left, label %right
left:
  %left.owner = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 68892 to ptr), i32 24, i1 false)
      to label %left.cont unwind label %unwind
left.cont:
  br label %merge
right:
  %right.owner = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 68892 to ptr), i32 24, i1 false)
      to label %right.cont unwind label %unwind
right.cont:
  br label %merge
merge:
  %owner = phi ptr addrspace(1) [ %left.owner, %left.cont ],
                                     [ %right.owner, %right.cont ]
  %slot = getelementptr inbounds i8, ptr addrspace(1) %owner, i64 16
  store atomic ptr addrspace(1) %child, ptr addrspace(1) %slot unordered, align 8
  call void @sink_owner(ptr addrspace(1) %owner)
  ret void
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @casec_owner_live(
; CHECK-COUNT-1: inttoptr (i64 68891 to ptr)
; CHECK-COUNT-2: inttoptr (i64 68892 to ptr)
; CHECK: store atomic ptr addrspace(1) %child
; CHECK: call void @sink_owner

; Unlike invoke_paths_after_overwrite, this invoke receives a still-virtual
; owner as a real argument.  Call-input processing must recursively
; materialize the live child and replay owner.child immediately before the
; invoke; the deopt slots must keep the same real identities on both edges.
define void @invoke_observes_virtual_owner() gc "hotspotgc"
    personality ptr @__gxx_personality_v0 {
entry:
  %child = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 68893 to ptr), i32 16, i1 false)
      to label %alloc.outer unwind label %alloc.unwind
alloc.outer:
  %outer = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 68894 to ptr), i32 24, i1 false)
      to label %body unwind label %alloc.unwind
body:
  %slot = getelementptr inbounds i8, ptr addrspace(1) %outer, i64 16
  store atomic ptr addrspace(1) %child, ptr addrspace(1) %slot unordered, align 8
  invoke void @observe_owner(ptr addrspace(1) %outer)
      [ "deopt"(i32 94, i32 94, i64 12,
                 ptr addrspace(1) %outer,
                 i64 4294967308, ptr addrspace(1) %child) ]
      to label %normal unwind label %handler
normal:
  ret void
handler:
  %lp = landingpad i64 cleanup
  resume i64 %lp
alloc.unwind:
  %alloc.lp = landingpad i64 cleanup
  resume i64 %alloc.lp
}

; CHECK-LABEL: define void @invoke_observes_virtual_owner(
; CHECK-COUNT-1: inttoptr (i64 68893 to ptr)
; CHECK-COUNT-1: inttoptr (i64 68894 to ptr)
; CHECK: %[[SLOT:[-A-Za-z$._0-9]+]] = getelementptr inbounds i8, ptr addrspace(1) %outer, i64 16
; CHECK-NEXT: store atomic ptr addrspace(1) %child, ptr addrspace(1) %[[SLOT]] unordered, align 8
; CHECK-NEXT: invoke void @observe_owner(ptr addrspace(1) %outer)
; CHECK-SAME: [ "deopt"(i32 94, i32 94, i64 12,
; CHECK-SAME: ptr addrspace(1) %outer,
; CHECK-SAME: i64 4294967308, ptr addrspace(1) %child) ]
; CHECK-NEXT: to label %normal unwind label %handler
; CHECK: handler:
; CHECK-NEXT: %lp = landingpad i64
; CHECK-NEXT: cleanup

; Once a root becomes ineligible, later stores target the real original
; allocation.  They must not receive new elimination effects.
define void @store_after_ineligible_root() gc "hotspotgc"
    personality ptr @__gxx_personality_v0 {
entry:
  %outer = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 68895 to ptr), i32 24, i1 false)
      to label %body unwind label %unwind
body:
  %is.vb = call hotspotcc i1 @jeandle.check_if_value_based(
      ptr addrspace(1) %outer)
  call void @use_bool(i1 %is.vb)
  %slot = getelementptr inbounds i8, ptr addrspace(1) %outer, i64 16
  store atomic i32 42, ptr addrspace(1) %slot unordered, align 4
  call void @sink_owner(ptr addrspace(1) %outer)
  ret void
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @store_after_ineligible_root(
; CHECK-COUNT-1: inttoptr (i64 68895 to ptr)
; CHECK: call hotspotcc i1 @jeandle.check_if_value_based
; CHECK: store atomic i32 42
; CHECK-NEXT: call void @sink_owner(ptr addrspace(1) %outer)

; The store path is visited before the sibling path makes the root ineligible.
; At the merge, the real sink must still observe that branch-local store.
define void @branch_store_other_branch_bails(i1 %bail) gc "hotspotgc"
    personality ptr @__gxx_personality_v0 {
entry:
  %outer = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 68896 to ptr), i32 24, i1 false)
      to label %choose unwind label %unwind
choose:
  %slot = getelementptr inbounds i8, ptr addrspace(1) %outer, i64 16
  br i1 %bail, label %bail.path, label %store.path
store.path:
  store atomic i32 77, ptr addrspace(1) %slot unordered, align 4
  br label %merge
bail.path:
  %is.vb = call hotspotcc i1 @jeandle.check_if_value_based(
      ptr addrspace(1) %outer)
  call void @use_bool(i1 %is.vb)
  br label %merge
merge:
  call void @sink_owner(ptr addrspace(1) %outer)
  ret void
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @branch_store_other_branch_bails(
; CHECK-COUNT-1: inttoptr (i64 68896 to ptr)
; CHECK: store.path:
; CHECK-NEXT: store atomic i32 77
; CHECK: bail.path:
; CHECK: call hotspotcc i1 @jeandle.check_if_value_based
; CHECK: merge:
; CHECK-NEXT: call void @sink_owner(ptr addrspace(1) %outer)

; Making the owner real also exposes the current child object.  The child's
; fields must retain the definitions that reach the same observation point.
define void @nested_state_before_link_bail() gc "hotspotgc"
    personality ptr @__gxx_personality_v0 {
entry:
  %child = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 68897 to ptr), i32 24, i1 false)
      to label %alloc.outer unwind label %unwind
alloc.outer:
  %outer = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 68898 to ptr), i32 24, i1 false)
      to label %body unwind label %unwind
body:
  %child.value = getelementptr inbounds i8, ptr addrspace(1) %child, i64 16
  store atomic i32 42, ptr addrspace(1) %child.value unordered, align 4
  %outer.child = getelementptr inbounds i8, ptr addrspace(1) %outer, i64 16
  store atomic ptr addrspace(1) %child, ptr addrspace(1) %outer.child unordered, align 8
  %is.vb = call hotspotcc i1 @jeandle.check_if_value_based(
      ptr addrspace(1) %outer)
  call void @use_bool(i1 %is.vb)
  call void @sink_owner(ptr addrspace(1) %outer)
  ret void
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @nested_state_before_link_bail(
; CHECK-COUNT-1: inttoptr (i64 68897 to ptr)
; CHECK-COUNT-1: inttoptr (i64 68898 to ptr)
; CHECK: store atomic i32 42
; CHECK: store atomic ptr addrspace(1) %child
; CHECK: call hotspotcc i1 @jeandle.check_if_value_based
; CHECK: call void @sink_owner(ptr addrspace(1) %outer)

; The child's reaching definition is sampled when the owner is observed, not
; when the owner.child link was first stored.
define void @nested_state_after_link_bail() gc "hotspotgc"
    personality ptr @__gxx_personality_v0 {
entry:
  %child = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 68899 to ptr), i32 24, i1 false)
      to label %alloc.outer unwind label %unwind
alloc.outer:
  %outer = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 68900 to ptr), i32 24, i1 false)
      to label %body unwind label %unwind
body:
  %outer.child = getelementptr inbounds i8, ptr addrspace(1) %outer, i64 16
  store atomic ptr addrspace(1) %child, ptr addrspace(1) %outer.child unordered, align 8
  %child.value = getelementptr inbounds i8, ptr addrspace(1) %child, i64 16
  store atomic i32 43, ptr addrspace(1) %child.value unordered, align 4
  %is.vb = call hotspotcc i1 @jeandle.check_if_value_based(
      ptr addrspace(1) %outer)
  call void @use_bool(i1 %is.vb)
  call void @sink_owner(ptr addrspace(1) %outer)
  ret void
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @nested_state_after_link_bail(
; CHECK-COUNT-1: inttoptr (i64 68899 to ptr)
; CHECK-COUNT-1: inttoptr (i64 68900 to ptr)
; CHECK: store atomic ptr addrspace(1) %child
; CHECK: store atomic i32 43
; CHECK: call hotspotcc i1 @jeandle.check_if_value_based
; CHECK: call void @sink_owner(ptr addrspace(1) %outer)

; A merge observation exposes every reaching child-field definition.
define void @nested_state_diamond_bail(i1 %choose) gc "hotspotgc"
    personality ptr @__gxx_personality_v0 {
entry:
  %child = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 68901 to ptr), i32 24, i1 false)
      to label %alloc.outer unwind label %unwind
alloc.outer:
  %outer = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 68902 to ptr), i32 24, i1 false)
      to label %choose.block unwind label %unwind
choose.block:
  %outer.child = getelementptr inbounds i8, ptr addrspace(1) %outer, i64 16
  store atomic ptr addrspace(1) %child, ptr addrspace(1) %outer.child unordered, align 8
  %child.value = getelementptr inbounds i8, ptr addrspace(1) %child, i64 16
  br i1 %choose, label %left, label %right
left:
  store atomic i32 51, ptr addrspace(1) %child.value unordered, align 4
  br label %merge
right:
  store atomic i32 52, ptr addrspace(1) %child.value unordered, align 4
  br label %merge
merge:
  %is.vb = call hotspotcc i1 @jeandle.check_if_value_based(
      ptr addrspace(1) %outer)
  call void @use_bool(i1 %is.vb)
  call void @sink_owner(ptr addrspace(1) %outer)
  ret void
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @nested_state_diamond_bail(
; CHECK-COUNT-1: inttoptr (i64 68901 to ptr)
; CHECK-COUNT-1: inttoptr (i64 68902 to ptr)
; CHECK: store atomic ptr addrspace(1) %child
; CHECK: store atomic i32 51
; CHECK: store atomic i32 52
; CHECK: call hotspotcc i1 @jeandle.check_if_value_based
; CHECK: call void @sink_owner(ptr addrspace(1) %outer)

; The point-specific observation closure handles both arbitrary depth and
; cycles.  Reaching leaf.value must survive together with all three links.
define void @nested_state_multilevel_cycle_bail() gc "hotspotgc"
    personality ptr @__gxx_personality_v0 {
entry:
  %leaf = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 68903 to ptr), i32 32, i1 false)
      to label %alloc.middle unwind label %unwind
alloc.middle:
  %middle = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 68904 to ptr), i32 24, i1 false)
      to label %alloc.outer unwind label %unwind
alloc.outer:
  %outer = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 68905 to ptr), i32 24, i1 false)
      to label %body unwind label %unwind
body:
  %leaf.value = getelementptr inbounds i8, ptr addrspace(1) %leaf, i64 16
  store atomic i32 61, ptr addrspace(1) %leaf.value unordered, align 4
  %leaf.outer = getelementptr inbounds i8, ptr addrspace(1) %leaf, i64 24
  store atomic ptr addrspace(1) %outer, ptr addrspace(1) %leaf.outer unordered, align 8
  %middle.leaf = getelementptr inbounds i8, ptr addrspace(1) %middle, i64 16
  store atomic ptr addrspace(1) %leaf, ptr addrspace(1) %middle.leaf unordered, align 8
  %outer.middle = getelementptr inbounds i8, ptr addrspace(1) %outer, i64 16
  store atomic ptr addrspace(1) %middle, ptr addrspace(1) %outer.middle unordered, align 8
  %is.vb = call hotspotcc i1 @jeandle.check_if_value_based(
      ptr addrspace(1) %outer)
  call void @use_bool(i1 %is.vb)
  call void @sink_owner(ptr addrspace(1) %outer)
  ret void
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @nested_state_multilevel_cycle_bail(
; CHECK-COUNT-1: inttoptr (i64 68903 to ptr)
; CHECK-COUNT-1: inttoptr (i64 68904 to ptr)
; CHECK-COUNT-1: inttoptr (i64 68905 to ptr)
; CHECK: store atomic i32 61
; CHECK: store atomic ptr addrspace(1) %outer
; CHECK: store atomic ptr addrspace(1) %leaf
; CHECK: store atomic ptr addrspace(1) %middle
; CHECK: call void @sink_owner(ptr addrspace(1) %outer)

; An invoke consuming an already-ineligible ghost owner must expose the same
; complete nested state on its normal and unwind edges.
define void @nested_state_invoke_after_bail() gc "hotspotgc"
    personality ptr @__gxx_personality_v0 {
entry:
  %child = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 68906 to ptr), i32 24, i1 false)
      to label %alloc.outer unwind label %alloc.unwind
alloc.outer:
  %outer = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 68907 to ptr), i32 24, i1 false)
      to label %body unwind label %alloc.unwind
body:
  %child.value = getelementptr inbounds i8, ptr addrspace(1) %child, i64 16
  store atomic i32 71, ptr addrspace(1) %child.value unordered, align 4
  %outer.child = getelementptr inbounds i8, ptr addrspace(1) %outer, i64 16
  store atomic ptr addrspace(1) %child, ptr addrspace(1) %outer.child unordered, align 8
  %is.vb = call hotspotcc i1 @jeandle.check_if_value_based(
      ptr addrspace(1) %outer)
  call void @use_bool(i1 %is.vb)
  invoke void @observe_owner(ptr addrspace(1) %outer)
      to label %normal unwind label %handler
normal:
  ret void
handler:
  %lp = landingpad i64 cleanup
  resume i64 %lp
alloc.unwind:
  %alloc.lp = landingpad i64 cleanup
  resume i64 %alloc.lp
}

; CHECK-LABEL: define void @nested_state_invoke_after_bail(
; CHECK-COUNT-1: inttoptr (i64 68906 to ptr)
; CHECK-COUNT-1: inttoptr (i64 68907 to ptr)
; CHECK: store atomic i32 71
; CHECK: store atomic ptr addrspace(1) %child
; CHECK: call hotspotcc i1 @jeandle.check_if_value_based
; CHECK: invoke void @observe_owner(ptr addrspace(1) %outer)
; CHECK-NEXT: to label %normal unwind label %handler
; CHECK: handler:
; CHECK-NEXT: %lp = landingpad i64
; CHECK-NEXT: cleanup

; An overwritten reference is not part of the observation closure.  Its child
; and the child's state remain dead even though the owner itself becomes real.
define void @nested_state_overwritten_before_bail() gc "hotspotgc"
    personality ptr @__gxx_personality_v0 {
entry:
  %child = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 68908 to ptr), i32 24, i1 false)
      to label %alloc.outer unwind label %unwind
alloc.outer:
  %outer = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 68909 to ptr), i32 24, i1 false)
      to label %body unwind label %unwind
body:
  %child.value = getelementptr inbounds i8, ptr addrspace(1) %child, i64 16
  store atomic i32 81, ptr addrspace(1) %child.value unordered, align 4
  %outer.child = getelementptr inbounds i8, ptr addrspace(1) %outer, i64 16
  store atomic ptr addrspace(1) %child, ptr addrspace(1) %outer.child unordered, align 8
  store atomic ptr addrspace(1) null, ptr addrspace(1) %outer.child unordered, align 8
  %is.vb = call hotspotcc i1 @jeandle.check_if_value_based(
      ptr addrspace(1) %outer)
  call void @use_bool(i1 %is.vb)
  call void @sink_owner(ptr addrspace(1) %outer)
  ret void
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @nested_state_overwritten_before_bail(
; CHECK-NOT: inttoptr (i64 68908 to ptr)
; CHECK-COUNT-1: inttoptr (i64 68909 to ptr)
; CHECK-NOT: store atomic i32 81
; CHECK-NOT: store atomic ptr addrspace(1) %child
; CHECK: store atomic ptr addrspace(1) null
; CHECK: call hotspotcc i1 @jeandle.check_if_value_based
; CHECK: call void @sink_owner(ptr addrspace(1) %outer)

!java-method-compilation = !{}
