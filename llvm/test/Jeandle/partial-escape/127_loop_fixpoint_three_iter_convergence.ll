; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Verify the fixpoint handles a non-trivial loop with multiple field
; mutations across iterations. Two field slots, both written on every
; iteration with the loop counter. The body reads both back and passes
; them to scalar @use. The convergence check passes once the back-edge
; state is stable.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @use2(i32, i32)
declare i32 @__gxx_personality_v0(...)

define void @test_three_iter(i32 %n) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 24, i1 false)
       to label %prep unwind label %u
prep:
  %sa = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  %sb = getelementptr inbounds i8, ptr addrspace(1) %o, i64 12
  store atomic i32 7, ptr addrspace(1) %sa unordered, align 4
  store atomic i32 11, ptr addrspace(1) %sb unordered, align 4
  br label %loop
loop:
  %i = phi i32 [ 0, %prep ], [ %i1, %body ]
  %c = icmp slt i32 %i, %n
  br i1 %c, label %body, label %exit
body:
  %va = load atomic i32, ptr addrspace(1) %sa unordered, align 4
  %vb = load atomic i32, ptr addrspace(1) %sb unordered, align 4
  call void @use2(i32 %va, i32 %vb)
  %newa = add i32 %va, %i
  %newb = add i32 %vb, %i
  store atomic i32 %newa, ptr addrspace(1) %sa unordered, align 4
  store atomic i32 %newb, ptr addrspace(1) %sb unordered, align 4
  %i1 = add i32 %i, 1
  br label %loop
exit:
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; The object is fully eliminated. Two field-PHIs are emitted at the loop
; header (one per slot), with incoming [preheader-const, body-store-
; result]. The body's loads fold to the PHIs, the body's stores are
; gone, and @use2 consumes the PHI values. Without back-edge propagation
; (restoreLoopSnapshot preserves loop-block BlockExits across
; iterations), the body's @use2 would have been fed by the preheader
; constants 7/11 — unsound for n > 1, since the body's stores update the
; field on each iteration.
; CHECK-LABEL: define void @test_three_iter
; CHECK-NOT: jeandle.new_instance
; CHECK-NOT: store atomic
; CHECK-NOT: load atomic
; CHECK: %[[PA:[A-Za-z0-9._]+]] = phi i32 [ %newa, %body ], [ 7, %prep ]
; CHECK: %[[PB:[A-Za-z0-9._]+]] = phi i32 [ %newb, %body ], [ 11, %prep ]
; CHECK: call void @use2(i32 %[[PA]], i32 %[[PB]])
; CHECK: %newa = add i32 %[[PA]], %i
; CHECK: %newb = add i32 %[[PB]], %i

!java-method-compilation = !{}
