; RUN: opt -disable-output -verify-each \
; RUN:   -passes="require<partial-escape-analysis>" -jeandle-trace-pea \
; RUN:   -jeandle-dump-pea-stats -jeandle-pea-analyze-function=casea_invoke_normal_edge \
; RUN:   %s 2>&1 | FileCheck %s --check-prefix=TRACE \
; RUN:     --implicit-check-not='PEA: Materialize function=@casea_invoke_normal_edge'
; RUN: opt -S -verify-each \
; RUN:   -passes="require<partial-escape-analysis>,partial-escape-transform" \
; RUN:   %s | FileCheck %s --check-prefix=FINAL \
; RUN:     --implicit-check-not='invoke hotspotcc ptr addrspace(1) @jeandle.new_instance'

; The selected PHI cannot use Case C because %a remains independently
; observable at sink2.  Case A must materialize each virtual incoming on its
; own edge.  %b is defined by the allocation invoke that terminates its
; predecessor, so its real identity becomes available on the invoke's normal
; edge, not before the invoke.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink2(ptr addrspace(1), ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @casea_invoke_normal_edge(i1 %same, i32 %left, i32 %right)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
           ptr inttoptr (i64 69701 to ptr), i32 24, i1 false)
       [ "deopt"(i32 1, i32 1) ]
       to label %choose unwind label %unwind

choose:
  br i1 %same, label %merge, label %alloc.b

alloc.b:
  %b = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
           ptr inttoptr (i64 69701 to ptr), i32 24, i1 false)
       [ "deopt"(i32 2, i32 2, i64 12, ptr addrspace(1) %a) ]
       to label %merge unwind label %unwind

merge:
  %selected = phi ptr addrspace(1) [ %a, %choose ], [ %b, %alloc.b ]
  %af = getelementptr inbounds i8, ptr addrspace(1) %a, i64 16
  %sf = getelementptr inbounds i8, ptr addrspace(1) %selected, i64 16
  store atomic i32 %left, ptr addrspace(1) %af unordered, align 4
  store atomic i32 %right, ptr addrspace(1) %sf unordered, align 4
  call void @sink2(ptr addrspace(1) %a, ptr addrspace(1) %selected)
       [ "deopt"(i32 3, i32 3,
                   i64 12, ptr addrspace(1) %a,
                   i64 4294967308, ptr addrspace(1) %selected) ]
  ret void

unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; %a materializes on both identity-PHI paths; %b materializes once on the
; allocation invoke's normal edge.
; TRACE: PEA: Materialize function=@casea_invoke_normal_edge [VO=0] block=%choose
; TRACE-COUNT-1: PEA: Materialize function=@casea_invoke_normal_edge [VO=1]
; TRACE: PEA: Materialize function=@casea_invoke_normal_edge [VO=0] block=%alloc.b
; TRACE: PEA stats @casea_invoke_normal_edge: NeverEscapes=0 PartiallyEscapes=2 AlwaysEscapes=0

; FINAL-LABEL: define void @casea_invoke_normal_edge(
; FINAL-COUNT-2: invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; FINAL: %selected = phi ptr addrspace(1) [ %a, %choose ], [ %b, %alloc.b ]
; FINAL: store atomic i32 %left
; FINAL: store atomic i32 %right
; FINAL: call void @sink2(ptr addrspace(1) %a, ptr addrspace(1) %selected)
; FINAL-NOT: poison

!java-method-compilation = !{}
