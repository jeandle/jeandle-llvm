; REQUIRES: asserts
; RUN: opt -disable-output -passes="require<partial-escape-analysis>,partial-escape-transform" \
; RUN:     -stats %s 2>&1 | FileCheck %s

; The STATISTIC counters defined in
; PartialEscapeAnalysis.cpp must surface via standard `-stats`. This test
; exercises a virtualized allocation plus a materialization triggered by a
; sibling escape; the relevant counters should advance.
;
; The exact count is unimportant for the FileCheck contract — what matters is
; that the named counters appear in the -stats output with a positive value.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @t_stats_virt() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
         to label %n unwind label %u
n:
  %slot = getelementptr inbounds i8, ptr addrspace(1) %a, i64 8
  store atomic i32 7, ptr addrspace(1) %slot unordered, align 4
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

define void @t_stats_mat(i1 %c) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 22222 to ptr), i32 16, i1 false)
         to label %n unwind label %u
n:
  br i1 %c, label %esc, label %loc
esc:
  ; Escape forces a Materialize effect (Unhandled reason).
  call void @sink(ptr addrspace(1) %a)
  br label %merge
loc:
  br label %merge
merge:
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; -stats prints a "Statistics Collected" table to stderr with one line per
; counter, formatted as `<count> <DEBUG_TYPE> - <description>`. We match on
; the descriptions defined in PartialEscapeAnalysis.cpp's STATISTIC macros.
; CHECK-DAG: partial-escape-analysis - Number of virtual objects PEA created
; CHECK-DAG: partial-escape-analysis - Number of allocations eliminated (erased) by PEA
; CHECK-DAG: partial-escape-analysis - Number of materializations emitted by PEA
; CHECK-DAG: partial-escape-analysis - Materializations for unhandled instruction (escape point)
;
; JeandlePEAEliminated counts ONLY NeverEscapes allocations (= erased): here
; t_stats_virt's allocation is fully eliminated (count 1), while t_stats_mat's
; allocation PartiallyEscapes and OrigAlloc is KEPT alive by the transform
; (count 0) — so the total eliminated count is 1, matching what -stats prints.
; The PartiallyEscapes case is suppressed by
; EliminateAllocationEffect::apply (see PartialEscapeTransform.cpp:541-542) and
; MUST NOT be counted, only NeverEscapes are erased.

!java-method-compilation = !{}
