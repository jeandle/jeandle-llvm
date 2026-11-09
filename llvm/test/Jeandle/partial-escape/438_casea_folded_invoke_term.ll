; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Case-A with a folded JavaOp invoke terminator under the reuse-OrigAlloc
; model.
;
; %o is allocated via @jeandle.new_array. `else`'s terminator is an invoke of
; @jeandle.arraylength on the virtual %o, which folds (ReplaceCall erases the
; invoke; else's terminator becomes a plain branch). PEA must tolerate the
; erased terminator: any pending insertion point aimed at it has to be
; re-aimed at the in-block successor before the erased value's handle is
; nulled, and no dangling-insertion-point assert may fire.
;
; Under reuse-OrigAlloc the original allocation %o is retained, the
; arraylength is folded away, and the merge PHI's else-incoming is OrigAlloc
; %o directly (no field replay: %o has no tracked field store). No
; additional allocation invoke, no continuation block, no split.

declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32, i1, i1)
declare hotspotcc i32 @jeandle.arraylength(ptr addrspace(1) readonly)
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @casea_folded_invoke_term(i1 %c) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 12345 to ptr), i32 7, i32 44, i32 16, i32 1048576, i1 false, i1 false)
         to label %n unwind label %u
n:
  br i1 %c, label %then, label %else
then:
  br label %merge
else:
  ; arraylength on the virtual %o folds -> ReplaceCall erases this invoke
  ; (else's terminator). else has two successors (merge, handler).
  %len = invoke hotspotcc i32 @jeandle.arraylength(ptr addrspace(1) %o)
              to label %merge unwind label %handler
merge:
  ; PHI mixing %o virtual (else arm) and null (then arm) -> Case A: the
  ; else-incoming's real identity is OrigAlloc %o.
  %p = phi ptr addrspace(1) [ null, %then ], [ %o, %else ]
  call void @sink(ptr addrspace(1) %p)
  ret void
handler:
  %lp = landingpad i64 cleanup
  resume i64 %lp
u:
  %lpr = landingpad i64 cleanup
  resume i64 %lpr
}

; CHECK-LABEL: define void @casea_folded_invoke_term
; The original allocation invoke is retained.
; CHECK: invoke hotspotcc{{.*}}@jeandle.new_array
; The arraylength invoke was folded away (absent from entry..merge, where it
; sat in `else`).
; CHECK-NOT: @jeandle.arraylength
; No additional allocation invoke, continuation block, or split.
; CHECK-NOT: pea.mat = invoke
; CHECK-NOT: mat.cont
; CHECK-NOT: pea.crit.split
; CHECK: merge:
; The merge PHI's else-incoming is OrigAlloc %o directly.
; CHECK-NEXT: %p = phi ptr addrspace(1) [ null, %then ], [ %o, %else ]
; CHECK: call void @sink
; CHECK: ret void

!java-method-compilation = !{}
