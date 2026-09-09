; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Two-level loop nest where BOTH levels carry a distinct virtual object.
; The outer loop carries %o's field (1 -> %i across the outer back-edge);
; the inner loop carries %q's field (7 -> %j across the inner back-edge).
; %q is allocated in the outer body and consumed before the outer back-edge.
; Pins per-level B isolation: the per-call context stack must
; keep the outer loop's B and the inner loop's B distinct (the inner loop's
; header captures must not clobber the outer's).

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @use(i32)
declare i32 @__gxx_personality_v0(...)

define void @test_nested_both_carried(i32 %n, i32 %m) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 40301 to ptr), i32 16, i1 false)
       to label %prep unwind label %u
prep:
  %s = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  store atomic i32 1, ptr addrspace(1) %s unordered, align 4
  br label %oloop
oloop:
  %i = phi i32 [ 0, %prep ], [ %i2, %iexit ]
  %c = icmp slt i32 %i, %n
  br i1 %c, label %obody, label %oexit
obody:
  %q = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 40302 to ptr), i32 16, i1 false)
       to label %iprep unwind label %u
iprep:
  %t = getelementptr inbounds i8, ptr addrspace(1) %q, i64 8
  store atomic i32 7, ptr addrspace(1) %t unordered, align 4
  br label %iloop
iloop:
  %j = phi i32 [ 0, %iprep ], [ %j1, %ibody ]
  %cj = icmp slt i32 %j, %m
  br i1 %cj, label %ibody, label %iexit
ibody:
  store atomic i32 %j, ptr addrspace(1) %t unordered, align 4
  %w = load atomic i32, ptr addrspace(1) %t unordered, align 4
  call void @use(i32 %w)
  %j1 = add i32 %j, 1
  br label %iloop
iexit:
  store atomic i32 %i, ptr addrspace(1) %s unordered, align 4
  %v = load atomic i32, ptr addrspace(1) %s unordered, align 4
  call void @use(i32 %v)
  %i2 = add i32 %i, 1
  br label %oloop
oexit:
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; Both allocs eliminated; inner load folds to %j, outer load folds to %i.
; CHECK-LABEL: define void @test_nested_both_carried
; CHECK-NOT: jeandle.new_instance
; CHECK-NOT: store atomic
; CHECK-NOT: load atomic
; CHECK: call void @use(i32 %j)
; CHECK: call void @use(i32 %i)

!java-method-compilation = !{}
