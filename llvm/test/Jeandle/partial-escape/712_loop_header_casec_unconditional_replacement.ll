; RUN: opt -S -passes="loop-simplify,require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s
; RUN: opt -disable-output -passes="loop-simplify,require<partial-escape-analysis>" \
; RUN:     -jeandle-dump-pea-stats %s 2>&1 | FileCheck %s --check-prefix=STATS

; Variant of 711 without the in-loop join: the back-edge carries the fresh
; allocation DIRECTLY (unconditional replacement), so the header Case C merges
; two ordinary virtual objects [VO0, VO1]. Same expectation: both eliminated.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare i32 @__gxx_personality_v0(...)

define i32 @test_carried_casec_unconditional(i32 %n)
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
  %i = phi i32 [ 0, %ph ], [ %i1, %rn ]
  %p = phi ptr addrspace(1) [ %v0, %ph ], [ %v1, %rn ]
  %sp = getelementptr inbounds i8, ptr addrspace(1) %p, i64 8
  %x = load i32, ptr addrspace(1) %sp
  %x1 = add i32 %x, 1
  store i32 %x1, ptr addrspace(1) %sp
  br label %replace
replace:
  %v1 = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 22222 to ptr), i32 16, i1 false)
        to label %rn unwind label %u
rn:
  %i1 = add i32 %i, 1
  %c = icmp slt i32 %i1, %n
  br i1 %c, label %loop, label %exit
exit:
  %se = getelementptr inbounds i8, ptr addrspace(1) %p, i64 8
  %xe = load i32, ptr addrspace(1) %se
  ret i32 %xe
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; The loop always reads the current object's default field (the back-edge
; object is freshly allocated each iteration, so the read folds to 0 — a
; carried-increment chain here would be a miscompile), and the exit returns
; the incremented value of the object carried into the last iteration.
; CHECK-LABEL: define i32 @test_carried_casec_unconditional
; CHECK-NOT: jeandle.new_instance
; CHECK: %[[X1:.*]] = add i32 0, 1
; CHECK: ret i32 %[[X1]]
; CHECK-NOT: poison

; STATS: ;; PEA stats @test_carried_casec_unconditional: NeverEscapes=2 PartiallyEscapes=0 AlwaysEscapes=0

!java-method-compilation = !{}
