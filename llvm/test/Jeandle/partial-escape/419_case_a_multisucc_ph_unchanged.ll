; REQUIRES: asserts
; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Case-A regression guard under the reuse-OrigAlloc model. An LLVM pointer
; PHI at `merge` mixes a virtual incoming (o from `else`, which has TWO
; successors) with a non-virtual incoming (null from `then`).
;
; OrigAlloc %o dominates every successor and there is no field or lock state
; to replay, so Case A needs no physical materialization effect: `else`
; retains its original multi-successor branch unchanged, and the merge PHI's
; else-incoming stays %o directly. No split block or additional allocation is
; needed. (There is no field-value PHI either: o has no tracked field
; disagreement here.)

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @repro(i1 %c, i1 %c2)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %n unwind label %u
n:
  br i1 %c, label %then, label %else
then:
  br label %merge
else:
  ; o is virtual. TWO successors: merge and S.
  br i1 %c2, label %merge, label %S
merge:
  ; LLVM PHI mixing virtual (o from else) and non-virtual (null from then)
  ; -> Case A: retain OrigAlloc as the virtual incoming's real identity.
  %p = phi ptr addrspace(1) [ null, %then ], [ %o, %else ]
  call void @sink(ptr addrspace(1) %p)
  ret void
S:
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @repro
; The original allocation invoke is retained.
; CHECK: invoke hotspotcc{{.*}}@jeandle.new_instance
; INVARIANT: no additional allocation, replay block, or critical-edge split.
; CHECK-NOT: pea.mat = invoke
; CHECK-NOT: pea.crit.split
; CHECK-NOT: mat.cont
; `else` is UNCHANGED: its original multi-successor branch is retained.
; CHECK: else:
; CHECK-NEXT: br i1 %c2, label %merge, label %S
; The merge PHI's else-incoming is OrigAlloc %o directly.
; CHECK: merge:
; CHECK-NEXT: %p = phi ptr addrspace(1) [ null, %then ], [ %o, %else ]
; CHECK: call void @sink(ptr addrspace(1) %p)
; CHECK: ret void

!java-method-compilation = !{}
