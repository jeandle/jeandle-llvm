; REQUIRES: asserts
; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Two-target per-pred materialization under the reuse-OrigAlloc model. PH
; (`else`) has TWO successor merges (merge1, merge2), BOTH mixed (split arm
; materialized via sink, else arm virtual).
;
; OrigAlloc %o dominates both merges. Because this object has no field or lock
; state to replay, the per-merge state transitions require no physical
; side-effect and no critical edge is split: `else` retains its original
; two-successor branch, and both merge sinks consume %o directly. No
; additional allocation or materialized-object PHI is needed.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @repro(i1 %c, i1 %c2, i1 %c3, i32 %v)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %n unwind label %u
n:
  br i1 %c, label %then1, label %else
then1:
  call void @sink(ptr addrspace(1) %o)
  br label %split
split:
  br i1 %c3, label %merge1, label %merge2
else:
  ; o is virtual. TWO successors: merge1 and merge2, both mixed merges.
  br i1 %c2, label %merge1, label %merge2
merge1:
  ; preds: split (materialized), else (virtual) -> merge state uses OrigAlloc.
  call void @sink(ptr addrspace(1) %o)
  ret void
merge2:
  ; preds: split (materialized), else (virtual) -> merge state uses OrigAlloc.
  call void @sink(ptr addrspace(1) %o)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @repro
; The original allocation invoke is retained.
; CHECK: invoke hotspotcc{{.*}}@jeandle.new_instance
; No materialization invokes, no splits.
; CHECK-NOT: pea.mat = invoke
; CHECK-NOT: pea.crit.split
; `else` retains its original two-successor branch to merge1/merge2.
; CHECK: else:
; CHECK-NEXT: br i1 %c2, label %merge1, label %merge2
; Both merges escape OrigAlloc %o directly; no object PHI is needed.
; CHECK: merge1:
; CHECK: call void @sink(ptr addrspace(1) %o)
; CHECK: ret void
; CHECK: merge2:
; CHECK: call void @sink(ptr addrspace(1) %o)
; CHECK: ret void

!java-method-compilation = !{}
