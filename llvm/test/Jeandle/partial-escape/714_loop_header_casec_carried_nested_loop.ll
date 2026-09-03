; RUN: opt -S -passes="loop-simplify,require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s
; RUN: opt -disable-output -passes="loop-simplify,require<partial-escape-analysis>" \
; RUN:     -jeandle-dump-pea-stats %s 2>&1 | FileCheck %s --check-prefix=STATS

; Nested-loop variant of 711: the carried-replacement pattern lives in the
; INNER loop, while the same object is also carried across the OUTER loop's
; back-edge. Both loops' header Case C must merge and both allocations must
; be eliminated. Stresses the body-pass context stack (outer pass recursing
; into the inner fixpoint): the inner header's back-edge incoming must
; abstain during the inner body pass, while the outer header's back-edge
; incoming (which flows through the whole inner loop) must abstain during
; the outer body pass — never the reverse.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare i32 @__gxx_personality_v0(...)

define i32 @test_carried_casec_nested(i32 %n, i32 %m)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %v0 = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 22222 to ptr), i32 16, i1 false)
        to label %ph unwind label %u
ph:
  %s0 = getelementptr inbounds i8, ptr addrspace(1) %v0, i64 8
  store i32 0, ptr addrspace(1) %s0
  br label %outer
outer:
  %i = phi i32 [ 0, %ph ], [ %i1, %olatch ]
  %po = phi ptr addrspace(1) [ %v0, %ph ], [ %pinner, %olatch ]
  br label %inner
inner:
  %j = phi i32 [ 0, %outer ], [ %j1, %ilatch ]
  %p = phi ptr addrspace(1) [ %po, %outer ], [ %pnext, %ilatch ]
  %sp = getelementptr inbounds i8, ptr addrspace(1) %p, i64 8
  %x = load i32, ptr addrspace(1) %sp
  %x1 = add i32 %x, 1
  store i32 %x1, ptr addrspace(1) %sp
  %cond = icmp sge i32 %x1, 100
  br i1 %cond, label %replace, label %ilatch
replace:
  %v1 = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 22222 to ptr), i32 16, i1 false)
        to label %rn unwind label %u
rn:
  br label %ilatch
ilatch:
  %pnext = phi ptr addrspace(1) [ %v1, %rn ], [ %p, %inner ]
  %j1 = add i32 %j, 1
  %c1 = icmp slt i32 %j1, %m
  br i1 %c1, label %inner, label %olatch
olatch:
  %pinner = phi ptr addrspace(1) [ %pnext, %ilatch ]
  %i1 = add i32 %i, 1
  %c2 = icmp slt i32 %i1, %n
  br i1 %c2, label %outer, label %exit
exit:
  %se = getelementptr inbounds i8, ptr addrspace(1) %pinner, i64 8
  %xe = load i32, ptr addrspace(1) %se
  ret i32 %xe
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; Both allocations eliminated; the merged field state threads correctly
; through both loops: the inner join PHI resets to 0 on the replace edge and
; feeds both the inner and outer header field PHIs; the exit returns it.
; CHECK-LABEL: define i32 @test_carried_casec_nested
; CHECK-NOT: jeandle.new_instance
; CHECK: %[[HO:pea.casec.field.phi[0-9]*]] = phi i32 [ 0, %ph ], [ %[[S:pea.casec.field.phi[0-9]*]], %olatch ]
; CHECK: %[[HI:pea.casec.field.phi[0-9]*]] = phi i32 [ %[[HO]], %outer ], [ %[[S]], %ilatch ]
; CHECK: %[[X1:.*]] = add i32 %[[HI]], 1
; CHECK: %[[S]] = phi i32 [ 0, %rn ], [ %[[X1]], %inner ]
; CHECK: ret i32 %[[S]]
; CHECK-NOT: poison

; STATS: ;; PEA stats @test_carried_casec_nested: NeverEscapes=2 PartiallyEscapes=0 AlwaysEscapes=0

!java-method-compilation = !{}
