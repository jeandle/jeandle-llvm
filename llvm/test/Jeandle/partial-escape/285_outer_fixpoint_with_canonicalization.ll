; RUN: opt -S -passes="partial-escape-iterative" -jeandle-pea-iterations=2 %s | FileCheck %s

; Outer-fixpoint with-canonicalization test. This input is specifically constructed so
; that:
;   - Round 1 PEA's analyzer CANNOT see the escape arm as dead (the guard
;     condition depends on two operations InstCombine can fold but PEA's
;     symbolic interpreter does not). PEA keeps %o at its source allocation
;     and replays its tracked field before the escape.
;   - Between rounds InstCombine performs a non-trivial fold:
;       %m = mul i32 %x, 0       ; -> 0
;       %s = sub i32 %m, %m      ; -> 0
;       %c = icmp ne i32 %s, 0   ; -> false
;     SimplifyCFG then drops the dead branch; ADCE removes orphaned replay.
;   - Round 2 PEA virtualizes %o and removes everything.
;
; The point: this round-between-passes (InstCombine/SimplifyCFG/ADCE) is
; doing more than just renaming or trivial-dead pruning — it's performing
; algebraic simplification that PEA itself never attempts. The test
; therefore exercises the wrapper's full canonicalization step, not just
; the PEA transform's own dead-code sweep.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define i32 @test_with_canonicalization(i32 %x)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %n unwind label %u
n:
  ; Algebraic chain that InstCombine reduces to constant `false`.
  %m = mul i32 %x, 0
  %s = sub i32 %m, %m
  %c = icmp ne i32 %s, 0
  br i1 %c, label %escape, label %fast
escape:
  call void @sink(ptr addrspace(1) %o)
  br label %fast
fast:
  %slot = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  store atomic i32 99, ptr addrspace(1) %slot unordered, align 4
  %val = load atomic i32, ptr addrspace(1) %slot unordered, align 4
  ret i32 %val
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define i32 @test_with_canonicalization(i32 %x)
; Round 2 folds the load to 99 and removes the dead escape branch. No
; allocation is introduced at the escape point.
; CHECK-NOT: call void @sink
; CHECK: ret i32 99

!java-method-compilation = !{}
