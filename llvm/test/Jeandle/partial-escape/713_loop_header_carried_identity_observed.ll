; RUN: opt -S -passes="loop-simplify,require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s
; RUN: opt -disable-output -passes="loop-simplify,require<partial-escape-analysis>" \
; RUN:     -jeandle-dump-pea-stats %s 2>&1 | FileCheck %s --check-prefix=STATS

; Same carried-replacement shape as 711, but the carried object's IDENTITY is
; observed: the loop compares the current object against the first allocation
; with ==. Case C is refused in this case (the two allocations must keep
; their distinct identities); Jeandle must stay equally conservative and
; retain both allocations.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare i1 @__gxx_personality_v0(...)

define i32 @test_carried_identity_observed(i32 %n)
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
  %same = phi i32 [ 0, %ph ], [ %same1, %latch ]
  %p = phi ptr addrspace(1) [ %v0, %ph ], [ %pnext, %latch ]
  %eq = icmp eq ptr addrspace(1) %p, %v0
  %eq32 = zext i1 %eq to i32
  %same1 = or i32 %same, %eq32
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
  %r = add i32 %xe, %same1
  ret i32 %r
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; Identity is observed: Case C must refuse the merge; both allocations stay,
; and the == compare survives as a REAL comparison (folding it to a constant
; from the carried phi's alias would be a miscompile: the result varies per
; dynamic iteration).
; CHECK-LABEL: define i32 @test_carried_identity_observed
; CHECK: invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK: icmp eq ptr addrspace(1) %p, %v0
; CHECK: invoke hotspotcc ptr addrspace(1) @jeandle.new_instance

; STATS: ;; PEA stats @test_carried_identity_observed: NeverEscapes=0 PartiallyEscapes=2 AlwaysEscapes=0

!java-method-compilation = !{}
