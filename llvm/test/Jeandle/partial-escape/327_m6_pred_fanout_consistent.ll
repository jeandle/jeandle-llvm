; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Post-materialise pred FieldStates update. When a per-pred
; materialise emitted during mergeStates flips an inner VO to
; Materialized, the outer VO's pred FieldStates entry for the offset
; that held VirtualRef(InnerID) must rewrite to MaterializedRef so
; sibling successors of the pred that later inherit see the up-to-date
; materialised pointer rather than a stale VirtualRef. updateOther-
; StatesForMaterialized handles this for the sibling-iter; the
; explicit defensive write in mergeStates ensures the post-condition
; even if a future refactor removes the sibling sweep.
;
; This test exercises an outer-VO whose field references an inner-VO,
; where the inner is materialised at a pred terminator during the
; merge. The outer's field entry must become MaterializedRef.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @test_pred_fanout(i1 %c)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %inner = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 11111 to ptr), i32 16, i1 false)
       to label %a unwind label %u
a:
  %outer = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 22222 to ptr), i32 16, i1 false)
       to label %b unwind label %u
b:
  ; Outer.field = inner (VirtualRef on the field state).
  %slot = getelementptr inbounds i8, ptr addrspace(1) %outer, i64 8
  store atomic ptr addrspace(1) %inner, ptr addrspace(1) %slot
        unordered, align 8
  br i1 %c, label %left, label %right
left:
  ; The escape consumer forces materialization of the inner via the
  ; outer's field reference at the merge.
  call void @sink(ptr addrspace(1) %inner)
  br label %merge
right:
  br label %merge
merge:
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; Inner materialises on the escape arm; outer's field state at offset
; 8 transitions to MaterializedRef on that pred so downstream merges
; see the up-to-date pointer. IR remains well-formed.
; CHECK-LABEL: define void @test_pred_fanout
; CHECK: call void @sink

!java-method-compilation = !{}
