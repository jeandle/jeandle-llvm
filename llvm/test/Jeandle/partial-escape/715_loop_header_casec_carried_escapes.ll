; RUN: opt -S -passes="loop-simplify,require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s
; RUN: opt -disable-output -passes="loop-simplify,require<partial-escape-analysis>" \
; RUN:     -jeandle-dump-pea-stats %s 2>&1 | FileCheck %s --check-prefix=STATS

; Same carried-replacement shape as 711, but the carried object ESCAPES after
; the loop via @sink. The header and join Case C synthesize a CYCLIC
; synthetic DAG (the header synthetic merges the preheader VO with the join
; synthetic, whose own sources include the header synthetic on later
; fixpoint passes). Materializing such a DAG at the escape point must fall
; back conservatively: both allocations are retained as real objects and the
; sink observes a valid identity — no poison, no half-replayed synthetic.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @test_carried_casec_escapes(i32 %n)
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
  call void @sink(ptr addrspace(1) %pnext)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; The carried object escapes: both allocations are retained and the sink
; receives a real object on every path.
; CHECK-LABEL: define void @test_carried_casec_escapes
; CHECK: invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK: invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK: call void @sink
; CHECK-NOT: poison

; STATS: ;; PEA stats @test_carried_casec_escapes: NeverEscapes=0 PartiallyEscapes=2 AlwaysEscapes=0

!java-method-compilation = !{}
