; RUN: opt -S -verify-each -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Incoming-edge materialization updates the target merge's predecessor view,
; but not the predecessor state shared with sibling successors.  The merge
; must retry after a pointer PHI materializes an incoming: an earlier PHI alias
; and the block body must be re-evaluated against the materialized view.

declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32)
declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare hotspotcc i32 @jeandle.arraylength(ptr addrspace(1) readonly)
declare void @may_throw()
declare void @mutate_object(ptr addrspace(1))
declare void @sink_i32(i32)
declare i32 @__gxx_personality_v0(...)

; A real invoke and a foldable arraylength invoke share an EH handler. Folding
; arraylength kills one unwind edge, so the handler has one live predecessor
; even though its LLVM PHIs still have two incoming edges during analysis. The
; dead incoming is deliberately ignored by PHI resolution: %alias.phi first
; becomes a virtual alias and the live constant-offset derived incoming of %p
; then forces Case A. The opaque call can change %o.field8 through %p; a later
; load through %alias.phi must not fold to the pre-call value.
define void @single_live_pred_view(i1 %take.real)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %arr = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
           ptr inttoptr (i64 67801 to ptr), i32 7, i32 44, i32 16,
           i32 1048576)
       to label %new.o unwind label %unwind
new.o:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
           ptr inttoptr (i64 67802 to ptr), i32 32, i1 false)
       to label %dispatch unwind label %unwind
dispatch:
  %slot = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  store atomic i32 19, ptr addrspace(1) %slot unordered, align 4
  %alias = freeze ptr addrspace(1) %o
  br i1 %take.real, label %real.path, label %killed.path
real.path:
  %derived = getelementptr i8, ptr addrspace(1) %o, i64 8
  invoke void @may_throw()
       to label %normal unwind label %handler
killed.path:
  %len = invoke hotspotcc i32 @jeandle.arraylength(ptr addrspace(1) %arr)
       to label %normal unwind label %handler
normal:
  ret void
handler:
  %alias.phi = phi ptr addrspace(1) [ %alias, %real.path ], [ null, %killed.path ]
  %p = phi ptr addrspace(1) [ %derived, %real.path ], [ null, %killed.path ]
  %handler.lp = landingpad i64 cleanup
  call void @mutate_object(ptr addrspace(1) %p)
  %after.slot = getelementptr inbounds i8, ptr addrspace(1) %alias.phi, i64 8
  %after = load atomic i32, ptr addrspace(1) %after.slot unordered, align 4
  call void @sink_i32(i32 %after)
  resume i64 %handler.lp
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @single_live_pred_view(
; CHECK-NOT: @jeandle.arraylength
; CHECK: store atomic i32 19
; CHECK: call void @mutate_object
; CHECK: %[[SINGLE_AFTER:.*]] = load atomic i32
; CHECK: call void @sink_i32(i32 %[[SINGLE_AFTER]])
; CHECK-NOT: call void @sink_i32(i32 19)

; Both exits initially carry byte-equivalent virtual state, exercising the
; identical-exit fast path.  The later PHI materializes only left on the first
; attempt.  A retry must then see left materialized and right virtual,
; materialize right as well, and preserve the path-dependent comparison.
define i32 @identical_exit_retry(i1 %c)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
           ptr inttoptr (i64 67803 to ptr), i32 32, i1 false)
       to label %dispatch unwind label %unwind
dispatch:
  %slot = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  store atomic i32 23, ptr addrspace(1) %slot unordered, align 4
  %alias = freeze ptr addrspace(1) %o
  br i1 %c, label %left, label %right
left:
  br label %merge
right:
  br label %merge
merge:
  %alias.phi = phi ptr addrspace(1) [ %alias, %left ], [ %alias, %right ]
  %p = phi ptr addrspace(1) [ %o, %left ], [ null, %right ]
  call void @mutate_object(ptr addrspace(1) %p)
  %after.slot = getelementptr inbounds i8, ptr addrspace(1) %alias.phi, i64 8
  %after = load atomic i32, ptr addrspace(1) %after.slot unordered, align 4
  ret i32 %after
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define i32 @identical_exit_retry(
; CHECK: left:
; CHECK: store atomic i32 23
; CHECK: right:
; CHECK: store atomic i32 23
; CHECK: merge:
; CHECK: call void @mutate_object
; CHECK: %[[MULTI_AFTER:.*]] = load atomic i32
; CHECK: ret i32 %[[MULTI_AFTER]]
; CHECK-NOT: ret i32 23

!java-method-compilation = !{}
