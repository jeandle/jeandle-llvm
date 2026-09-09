; REQUIRES: asserts
; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Per-pred materialization with a non-target successor under the
; reuse-OrigAlloc model. PH (`else`) has TWO successors: `merge` (mixed) and
; `D` (single-pred, o stays virtual, never escapes).
;
; OrigAlloc %o dominates every successor and is the real identity on escaping
; paths. The target-local materialized state for `merge` does not leak to `D`;
; because the virtual `else` state has no field or lock replay, no physical
; edge effect or split is needed. `D` remains a non-escaping path, and the
; then-arm escape replays the tracked field store onto %o before sinking it.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @repro(i1 %c, i1 %c2, i32 %v)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %n unwind label %u
n:
  br i1 %c, label %then, label %else
then:
  %slot = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  store atomic i32 %v, ptr addrspace(1) %slot unordered, align 4
  call void @sink(ptr addrspace(1) %o)
  br label %merge
else:
  ; o is virtual. TWO successors: merge and D.
  br i1 %c2, label %merge, label %D
merge:
  ; Mixed merge of then (materialized) and else (virtual); merge records
  ; OrigAlloc as the real identity for the virtual incoming.
  br label %exit
D:
  ; Single-pred (else). o stays virtual here, never escapes. No materialize.
  ret void
exit:
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @repro
; The original allocation invoke is retained.
; CHECK: invoke hotspotcc{{.*}}@jeandle.new_instance
; No materialization invokes and no critical-edge splits anywhere.
; CHECK-NOT: pea.mat = invoke
; CHECK-NOT: pea.crit.split
; The then arm replays the tracked field store onto OrigAlloc %o and escapes.
; CHECK: getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
; CHECK: call void @sink(ptr addrspace(1) %o)
; `else` retains its original two-successor branch (no split off else).
; CHECK: else:
; CHECK-NEXT: br i1 %c2, label %merge, label %D
; `D` is single-pred, o never escapes here: no invoke, just ret.
; CHECK: D:
; CHECK-NOT: invoke
; CHECK: ret void

!java-method-compilation = !{}
