; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" \
; RUN:     -jeandle-pea-loop-cutoff=1 %s | FileCheck %s

; StopNew -> Regular mode reset at depth==1 convergence.
;
; Two sequential loops in one function. Loop 1 is a 2-deep nest: with
; -jeandle-pea-loop-cutoff=1 its max depth (2) exceeds the cutoff, so the
; outermost processLoop enters Mode::StopNewInLoopNest and the depth-2
; loop-local alloc (klass 0x4444) is REFUSED from virtualization (it survives
; verbatim, like test 300). Loop 1 has no escape, so it CONVERGES in StopNew
; and the mode is reset to Regular at
; depth==1 success. Loop 2 is a sibling SINGLE loop (depth 1, max depth 1, not
; > cutoff) that must therefore run in Regular and fully virtualize its loop-
; local alloc (klass 0x5555). If the mode reset leaked, Loop 2's alloc would
; also be refused; the fact that it is eliminated proves the reset.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @use(i32)
declare i32 @__gxx_personality_v0(...)

define void @test_stop_new_then_regular(i32 %n) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  br label %o1
o1:
  %i1 = phi i32 [0, %entry], [%inc1, %l1]
  %c1 = icmp slt i32 %i1, %n
  br i1 %c1, label %b1, label %pre2
b1:
  br label %o2
o2:
  %i2 = phi i32 [0, %b1], [%inc2, %l2]
  %c2 = icmp slt i32 %i2, %n
  br i1 %c2, label %b2, label %l1
b2:
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
              ptr inttoptr (i64 4444 to ptr), i32 16, i1 false)
          to label %b2c unwind label %u
b2c:
  %s = getelementptr inbounds i8, ptr addrspace(1) %a, i64 8
  store atomic i32 7, ptr addrspace(1) %s unordered, align 4
  %v = load atomic i32, ptr addrspace(1) %s unordered, align 4
  call void @use(i32 %v)
  br label %l2
l2:
  %inc2 = add i32 %i2, 1
  br label %o2
l1:
  %inc1 = add i32 %i1, 1
  br label %o1

pre2:
  br label %o3
o3:
  %i3 = phi i32 [0, %pre2], [%inc3, %l3]
  %c3 = icmp slt i32 %i3, %n
  br i1 %c3, label %b3, label %exit
b3:
  %a2 = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
              ptr inttoptr (i64 5555 to ptr), i32 16, i1 false)
          to label %b3c unwind label %u
b3c:
  %s2 = getelementptr inbounds i8, ptr addrspace(1) %a2, i64 8
  store atomic i32 9, ptr addrspace(1) %s2 unordered, align 4
  %v2 = load atomic i32, ptr addrspace(1) %s2 unordered, align 4
  call void @use(i32 %v2)
  br label %l3
l3:
  %inc3 = add i32 %i3, 1
  br label %o3

exit:
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; Loop 1 (StopNew nest): the 0x4444 alloc is refused and survives; its load
; does NOT fold.
; CHECK-LABEL: define void @test_stop_new_then_regular
; CHECK: invoke {{.*}}@jeandle.new_instance({{.*}}i64 4444
; CHECK: call void @use(i32 %v)
; Loop 2 (Regular after reset): the 0x5555 alloc is eliminated and its load
; folds to 9. The CHECK-NOT scopes after the 5555 region.
; CHECK-NOT: i64 5555
; CHECK: call void @use(i32 9)

!java-method-compilation = !{}
