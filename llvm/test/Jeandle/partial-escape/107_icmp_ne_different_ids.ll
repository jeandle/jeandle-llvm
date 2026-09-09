; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Edge case: two virtual allocs A and B; `icmp ne %a, %b` should
; fold to true (different ObjectIDs => distinct identities). The branch
; should fold so the "same" arm becomes unreachable.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @use(i32)
declare i32 @__gxx_personality_v0(...)

define void @test_icmp_ne_different_ids() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 11111 to ptr), i32 16, i1 false)
       to label %nA unwind label %u1
nA:
  %b = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 22222 to ptr), i32 16, i1 false)
       to label %nB unwind label %u2
nB:
  %ne = icmp ne ptr addrspace(1) %a, %b
  br i1 %ne, label %live, label %dead
live:
  call void @use(i32 1)
  ret void
dead:
  call void @use(i32 -1)
  ret void
u1:
  %lp1 = landingpad i64 cleanup
  resume i64 %lp1
u2:
  %lp2 = landingpad i64 cleanup
  resume i64 %lp2
}

; The icmp folds to true. The "live" arm is reached; the "dead" arm is dead.
; Allocs are eliminated.
; CHECK-LABEL: define void @test_icmp_ne_different_ids
; CHECK-NOT: jeandle.new_instance
; CHECK-NOT: call void @use(i32 -1)
; CHECK: call void @use(i32 1)

!java-method-compilation = !{}
