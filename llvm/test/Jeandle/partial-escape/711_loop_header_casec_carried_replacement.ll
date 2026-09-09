; RUN: opt -S -passes="loop-simplify,require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s
; RUN: opt -disable-output -passes="loop-simplify,require<partial-escape-analysis>" \
; RUN:     -jeandle-dump-pea-stats %s 2>&1 | FileCheck %s --check-prefix=STATS

; Loop-carried replacement (Case C): an object allocated BEFORE the loop is
; carried by a loop-header pointer PHI, and conditionally REPLACED by a fresh
; allocation inside the loop body; the replacement flows to the back-edge
; through an in-loop join PHI. Identity of the carried object is never
; observed (only its field is read; no == comparison, no leak).
;
; Expected (Case C): the header Case C synthesizes one merged virtual
; object covering both allocations' field state, and BOTH allocations are
; eliminated (NeverEscapes=2).
;
; Regression anchor: at an in-pass header merge, a back-edge predecessor
; that has not yet been processed in the current body pass must be treated
; as unknown (abstain), exactly like the first iteration's missing back-edge
; exit data. Treating the back-edge incoming as a resolved non-virtual
; instead would make the Case-A fallback materialize the carried VO at the
; preheader (outside the loop, never rolled back), and the whole loop would
; cascade to materialization (PartiallyEscapes=2 instead of NeverEscapes=2).

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare i32 @__gxx_personality_v0(...)

define i32 @test_carried_casec(i32 %n)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %v0 = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 22222 to ptr), i32 16, i1 false)
        to label %ph unwind label %u
ph:
  %s0 = getelementptr inbounds i8, ptr addrspace(1) %v0, i64 8
  store i32 0, ptr addrspace(1) %s0
  br label %loop
loop:
  %i = phi i32 [ 0, %ph ], [ %i1, %latch ]
  %p = phi ptr addrspace(1) [ %v0, %ph ], [ %pnext, %latch ]
  %sp = getelementptr inbounds i8, ptr addrspace(1) %p, i64 8
  %x = load i32, ptr addrspace(1) %sp
  %x1 = add i32 %x, 1
  store i32 %x1, ptr addrspace(1) %sp
  %cond = icmp sge i32 %x1, 100
  br i1 %cond, label %replace, label %latch
replace:
  %v1 = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 22222 to ptr), i32 16, i1 false)
        to label %rn unwind label %u
rn:
  br label %latch
latch:
  %pnext = phi ptr addrspace(1) [ %v1, %rn ], [ %p, %loop ]
  %i1 = add i32 %i, 1
  %c = icmp slt i32 %i1, %n
  br i1 %c, label %loop, label %exit
exit:
  %se = getelementptr inbounds i8, ptr addrspace(1) %pnext, i64 8
  %xe = load i32, ptr addrspace(1) %se
  ret i32 %xe
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; Both allocations are NeverEscape: eliminated, all field loads folded to the
; merged field-PHI values; no replay, no poison. The merged field state must
; be exactly the Case-C result: the header field PHI selects the
; preheader default or the join PHI; the join PHI resets to the
; replacement's default 0 on the replace edge and carries the incremented
; value otherwise; the exit returns the join value.
; CHECK-LABEL: define i32 @test_carried_casec
; CHECK-NOT: jeandle.new_instance
; CHECK: %[[HX:pea.casec.field.phi[0-9]*]] = phi i32 [ 0, %ph ], [ %[[SX:pea.casec.field.phi[0-9]*]], %latch ]
; CHECK: %[[X1:.*]] = add i32 %[[HX]], 1
; CHECK: %[[SX]] = phi i32 [ 0, %rn ], [ %[[X1]], %loop ]
; CHECK: ret i32 %[[SX]]
; CHECK-NOT: poison

; STATS: ;; PEA stats @test_carried_casec: NeverEscapes=2 PartiallyEscapes=0 AlwaysEscapes=0

!java-method-compilation = !{}
