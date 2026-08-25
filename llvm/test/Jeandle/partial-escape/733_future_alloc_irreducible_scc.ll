; RUN: opt -passes=verify -disable-output %s
; RUN: opt -S -verify-each \
; RUN:   -passes="require<partial-escape-analysis>,partial-escape-transform" \
; RUN:   %s | FileCheck %s

; %cycle.alloc and %cycle.use form a reachable two-entry irreducible SCC.
; RPO can visit %cycle.use before discovering %obj in %cycle.alloc.  The
; allocation must stay real because LoopInfo has no Loop containing the SCC;
; otherwise the surviving PHI incoming and call would observe poison.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @future_alloc_irreducible_scc(i1 %entry.edge, i1 %backedge,
                                          ptr addrspace(1) %external)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  br i1 %entry.edge, label %cycle.use, label %cycle.alloc

cycle.alloc:
  %obj = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
             ptr inttoptr (i64 733 to ptr), i32 16, i1 false)
         to label %cycle.forward unwind label %unwind

cycle.forward:
  br label %cycle.use

cycle.use:
  %merged = phi ptr addrspace(1) [ %external, %entry ],
                                      [ %obj, %cycle.forward ]
  call void @sink(ptr addrspace(1) %merged)
  br i1 %backedge, label %cycle.alloc, label %exit

exit:
  ret void

unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

define void @future_alloc_indirectbr_scc(i1 %entry.edge, ptr %target,
                                         ptr addrspace(1) %external)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  br i1 %entry.edge, label %cycle.use, label %cycle.alloc

cycle.alloc:
  %obj = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
             ptr inttoptr (i64 734 to ptr), i32 16, i1 false)
         to label %cycle.forward unwind label %unwind

cycle.forward:
  br label %cycle.use

cycle.use:
  %merged = phi ptr addrspace(1) [ %external, %entry ],
                                      [ %obj, %cycle.forward ]
  call void @sink(ptr addrspace(1) %merged)
  indirectbr ptr %target, [label %cycle.alloc, label %exit]

exit:
  ret void

unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @future_alloc_irreducible_scc(
; CHECK: %obj = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
; CHECK: %merged = phi ptr addrspace(1) [ %external, %entry ], [ %obj, %cycle.forward ]
; CHECK: call void @sink(ptr addrspace(1) %merged)
; CHECK-NOT: poison
; CHECK-LABEL: define void @future_alloc_indirectbr_scc(
; CHECK: %obj = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
; CHECK: %merged = phi ptr addrspace(1) [ %external, %entry ], [ %obj, %cycle.forward ]
; CHECK: call void @sink(ptr addrspace(1) %merged)
; CHECK: indirectbr ptr %target, [label %cycle.alloc, label %exit]
; CHECK-NOT: poison

!java-method-compilation = !{}
