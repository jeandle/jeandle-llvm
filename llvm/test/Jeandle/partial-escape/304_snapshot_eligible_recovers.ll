; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; A loop-local object is allocated inside the body and consumed in-iter
; via a store/load of a primitive field. The allocation-site cache reuses
; the same ObjectID on later loop-fixpoint traversals. Ordinary B/B' retries
; must preserve its virtual state when no keep-real condition was observed,
; so the allocation remains eliminable after convergence.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @use(i32)
declare i32 @__gxx_personality_v0(...)

define void @test_eligible_recovers(i32 %n)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  br label %loop
loop:
  %i = phi i32 [ 0, %entry ], [ %i1, %cont ]
  %c = icmp slt i32 %i, %n
  br i1 %c, label %body, label %exit
body:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %st unwind label %u
st:
  %s = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  store atomic i32 %i, ptr addrspace(1) %s unordered, align 4
  %v = load atomic i32, ptr addrspace(1) %s unordered, align 4
  call void @use(i32 %v)
  br label %cont
cont:
  %i1 = add i32 %i, 1
  br label %loop
exit:
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; Loop-local alloc fully eliminated; load folds to the just-stored counter.
; CHECK-LABEL: define void @test_eligible_recovers
; CHECK-NOT: jeandle.new_instance
; CHECK-NOT: store atomic
; CHECK-NOT: load atomic
; CHECK: call void @use(i32 %i)

!java-method-compilation = !{}
