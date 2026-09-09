; REQUIRES: asserts
; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Three-successor per-pred materialization under the reuse-OrigAlloc model.
; PH (`else`) has THREE successors via a switch: merge1, merge2 (both mixed
; merges) and D (o virtual, no escape, single-pred).
;
; OrigAlloc %o dominates all three successors. With no field or lock state to
; replay, the two per-merge state transitions need no physical effects and no
; edge is split: `else` retains its original three-way switch verbatim. Both
; merge escapes consume %o directly, while `D` has no additional allocation
; or replay because the object does not escape there.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @repro(i1 %c, i1 %c3, i32 %c2, i32 %v)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %n unwind label %u
n:
  br i1 %c, label %then, label %else
then:
  call void @sink(ptr addrspace(1) %o)
  br label %split
split:
  br i1 %c3, label %merge1, label %merge2
else:
  ; o is virtual. THREE successors via switch: merge1, merge2, D.
  switch i32 %c2, label %D [ i32 0, label %merge1
                              i32 1, label %merge2 ]
merge1:
  ; preds: split (materialized), else (virtual) -> merge state uses OrigAlloc.
  call void @sink(ptr addrspace(1) %o)
  ret void
merge2:
  ; preds: split (materialized), else (virtual) -> merge state uses OrigAlloc.
  call void @sink(ptr addrspace(1) %o)
  ret void
D:
  ; Single-pred (else). o stays virtual, no escape.
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @repro
; The original allocation invoke is retained.
; CHECK: invoke hotspotcc{{.*}}@jeandle.new_instance
; No materialization invokes, no critical-edge splits.
; CHECK-NOT: pea.mat = invoke
; CHECK-NOT: pea.crit.split
; `else` retains its original three-way switch verbatim.
; CHECK: else:
; CHECK-NEXT: switch i32 %c2, label %D
; Both merge escapes consume OrigAlloc %o directly.
; CHECK: merge1:
; CHECK: call void @sink(ptr addrspace(1) %o)
; CHECK: ret void
; CHECK: merge2:
; CHECK: call void @sink(ptr addrspace(1) %o)
; CHECK: ret void
; `D` is single-pred, o never escapes: no invoke, just ret.
; CHECK: D:
; CHECK-NOT: invoke
; CHECK: ret void

!java-method-compilation = !{}
