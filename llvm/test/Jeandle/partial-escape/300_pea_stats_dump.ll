; RUN: opt -disable-output -passes="require<partial-escape-analysis>" \
; RUN:     -jeandle-dump-pea-stats %s 2>&1 | FileCheck %s

; EscapeClassification population + -jeandle-dump-pea-stats.
;
; Three functions cover the NeverEscapes / PartiallyEscapes classifications
; (AlwaysEscapes is not reachable from these patterns: processStore's
; unresolved-offset path materializes at the store rather than marking the
; object ineligible):
;
;  * @t_never:  one VO with a load/store pair, used only locally and never
;               escaped — eligible at commit() with no surviving Materialize
;               -> NeverEscapes.
;
;  * @t_partial: one VO that's allocated and stored to in the entry block,
;               then on one branch escapes via @sink (materialize emitted
;               before @sink) and on the other branch only reads the field.
;               At the merge the object is mixed (virtual on else, materialized
;               on if) but the alloc dominates the merge, so the VO is
;               classified PartiallyEscapes (Materialize effect survives,
;               and the original allocation is retained as OrigAlloc).
;
;  * @t_always: one VO with a store at a runtime (non-constant) byte offset.
;               processStore's resolveFieldOffset returns nullopt, so the
;               object materializes AT the store (Materialize effect survives,
;               OrigAlloc kept) and is stamped PartiallyEscapes.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare i32 @__gxx_personality_v0(...)
declare void @sink(ptr addrspace(1))

define i32 @t_never() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %obj = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
         to label %n unwind label %u
n:
  %slot = getelementptr inbounds i8, ptr addrspace(1) %obj, i64 8
  store atomic i32 7, ptr addrspace(1) %slot unordered, align 4
  %v = load atomic i32, ptr addrspace(1) %slot unordered, align 4
  ret i32 %v
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

define void @t_partial(i1 %c) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %obj = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 22222 to ptr), i32 16, i1 false)
         to label %n unwind label %u
n:
  %slot = getelementptr inbounds i8, ptr addrspace(1) %obj, i64 8
  store atomic i32 99, ptr addrspace(1) %slot unordered, align 4
  br i1 %c, label %esc, label %loc
esc:
  call void @sink(ptr addrspace(1) %obj)
  br label %merge
loc:
  %v = load atomic i32, ptr addrspace(1) %slot unordered, align 4
  br label %merge
merge:
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

define void @t_always(i64 %dyn_off) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %obj = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 33333 to ptr), i32 16, i1 false)
         to label %n unwind label %u
n:
  ; runtime byte offset -> resolveFieldOffset bails -> materialize at the
  ; store -> commit() stamps PartiallyEscapes.
  %slot = getelementptr inbounds i8, ptr addrspace(1) %obj, i64 %dyn_off
  store atomic i32 1, ptr addrspace(1) %slot unordered, align 4
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-DAG: ;; PEA stats @t_never: NeverEscapes=1 PartiallyEscapes=0 AlwaysEscapes=0
; CHECK-DAG: ;; PEA stats @t_partial: NeverEscapes=0 PartiallyEscapes=1 AlwaysEscapes=0
; CHECK-DAG: ;; PEA stats @t_always: NeverEscapes=0 PartiallyEscapes=1 AlwaysEscapes=0

!java-method-compilation = !{}
