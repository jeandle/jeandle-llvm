; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; MergeProcessor retry: alias re-derivation across fixpoint iterations.
;
; The merge combines two effects that force the do/while to run >= 2
; iterations AND exercise a Case-B pointer alias at the same merge:
;
;   1. The outer's reference field (offset 8) disagrees across arms:
;        left  stores a fresh virtual %inner
;        right stores the incoming pointer %p
;      mergeFieldStates resolves the left incoming by materializing %inner
;      at the left pred, which emits an Effect and sets Changed=true ->
;      the per-VO loop re-runs (the iterative-stabilization fixpoint).
;
;   2. A Case-B pointer PHI %ophi (both incomings are %outer) at the same
;      merge is aliased to %outer's VO. On the retry iteration the
;      per-phi alias is cleared and re-derived; the downstream load of the
;      uniform scalar field (offset 16 = 7, stored before the branch) must
;      still fold to the constant 7 through the re-derived alias.
;
; This is the key regression test for the merge retry (reset-output-state
; + clear-effect-buffer + per-phi Aliases.resetAlias): if the alias is not
; correctly re-derived after a retry, the @use(i32 7) fold breaks.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(ptr addrspace(1))
declare void @use(i32)
declare i32 @__gxx_personality_v0(...)

define void @test_alias_redrive(i1 %c, ptr addrspace(1) %p)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %outer = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
              ptr inttoptr (i64 67890 to ptr), i32 32, i1 false)
           to label %n unwind label %u
n:
  %sk = getelementptr inbounds i8, ptr addrspace(1) %outer, i64 16
  store atomic i32 7, ptr addrspace(1) %sk unordered, align 4
  br i1 %c, label %left, label %right
left:
  %inner = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
              ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
           to label %lcont unwind label %u
lcont:
  %sl = getelementptr inbounds i8, ptr addrspace(1) %outer, i64 8
  store atomic ptr addrspace(1) %inner, ptr addrspace(1) %sl unordered, align 8
  br label %merge
right:
  %sr = getelementptr inbounds i8, ptr addrspace(1) %outer, i64 8
  store atomic ptr addrspace(1) %p, ptr addrspace(1) %sr unordered, align 8
  br label %merge
merge:
  %ophi = phi ptr addrspace(1) [ %outer, %lcont ], [ %outer, %right ]
  %sk2 = getelementptr inbounds i8, ptr addrspace(1) %ophi, i64 16
  %kv = load atomic i32, ptr addrspace(1) %sk2 unordered, align 4
  %sm = getelementptr inbounds i8, ptr addrspace(1) %outer, i64 8
  %v = load atomic ptr addrspace(1), ptr addrspace(1) %sm unordered, align 8
  call void @sink(ptr addrspace(1) %v)
  call void @use(i32 %kv)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; Outer (klass 67890) fully scalar-replaced; inner (klass 12345) materialized
; on the left arm; the ref field carries a ptr addrspace(1) PHI. The Case-B
; alias on %ophi survives the retry: the load of the uniform scalar field
; folds to 7.
; CHECK-LABEL: define void @test_alias_redrive
; CHECK-NOT: i64 67890
; CHECK: invoke hotspotcc{{.*}}@jeandle.new_instance(ptr inttoptr (i64 12345 to ptr)
; CHECK: = phi ptr addrspace(1)
; CHECK: call void @sink
; CHECK: call void @use(i32 7)
; CHECK: ret void

!java-method-compilation = !{}
