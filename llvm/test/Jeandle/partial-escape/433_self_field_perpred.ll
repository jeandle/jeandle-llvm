; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Self-referential field (o.f = o) across a mixed merge.
;
; `else` keeps o virtual and stores o into its own field (offset 8); `then`
; escapes o via sink. Under reuse-OrigAlloc the single OrigAlloc dominates
; both arms and the merge, so o is kept alive as the one SSA value: the
; self-referential field replays onto OrigAlloc (storing %o into its own
; field), both sink calls receive OrigAlloc directly, and NO materialized-
; object PHI or additional allocation is needed at the merge.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @self_field_perpred(i1 %c) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 12345 to ptr), i32 16, i1 false) to label %n unwind label %u
n:
  br i1 %c, label %then, label %else
then:
  call void @sink(ptr addrspace(1) %o)
  br label %merge
else:
  %slot = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  store atomic ptr addrspace(1) %o, ptr addrspace(1) %slot unordered, align 8
  br label %merge
merge:
  call void @sink(ptr addrspace(1) %o)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

!java-method-compilation = !{}

; CHECK-LABEL: define void @self_field_perpred
; Exactly one allocation invoke (the original OrigAlloc, retained).
; CHECK: invoke hotspotcc{{.*}}@jeandle.new_instance(ptr inttoptr (i64 12345 to ptr)
; CHECK-NOT: pea.mat = invoke
; The self-referential field store replays onto OrigAlloc — value operand is
; the live OrigAlloc %o, never <badref>.
; CHECK: %[[SLOT:[A-Za-z0-9._]+]] = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
; CHECK: store atomic ptr addrspace(1) %o, ptr addrspace(1) %[[SLOT]] unordered, align 8
; No materialized-object PHI at the merge: OrigAlloc is the single SSA value
; consumed by both sink calls.
; CHECK-NOT: phi
; CHECK: call void @sink(ptr addrspace(1) %o)
; CHECK: ret void
