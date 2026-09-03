; RUN: opt -S -passes="partial-escape-iterative" -jeandle-pea-iterations=2 %s | FileCheck %s

; Natural-path re-foldable materialization. Round 1 keeps %o at its original
; allocation site and replays both tracked fields before the escape consumer.
; Canonicalization between rounds folds the load+icmp and drops the dead
; escape arm. Round 2 then analyzes the surviving OrigAlloc and replay-derived
; state without introducing or relocating an allocation.
;
; What differs from 280: we write TWO fields, then read them back on the
; fast path. The retained source allocation carries replay for both stores,
; which round 2 re-folds into virtual state.

@G_zero = private unnamed_addr constant i32 0

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define i64 @test_b8_natural_refold()
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 24, i1 false)
       to label %n unwind label %u
n:
  %v = load i32, ptr @G_zero, align 4
  %c = icmp ne i32 %v, 0
  br i1 %c, label %escape, label %fast
escape:
  call void @sink(ptr addrspace(1) %o)
  br label %fast
fast:
  %slot1 = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  %slot2 = getelementptr inbounds i8, ptr addrspace(1) %o, i64 16
  store atomic i32 7, ptr addrspace(1) %slot1 unordered, align 4
  store atomic i32 35, ptr addrspace(1) %slot2 unordered, align 4
  %v1 = load atomic i32, ptr addrspace(1) %slot1 unordered, align 4
  %v2 = load atomic i32, ptr addrspace(1) %slot2 unordered, align 4
  %sum32 = add i32 %v1, %v2
  %sum = sext i32 %sum32 to i64
  ret i64 %sum
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define i64 @test_b8_natural_refold()
; Round 2 folds the loads to the constants and removes the dead escape branch.
; The source allocation is retained only if the final explicit path still
; needs its physical identity.
; CHECK-NOT: call void @sink
; CHECK: ret i64 42

!java-method-compilation = !{}
