; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" -jeandle-pea-loop-cutoff=2 %s | FileCheck %s

; Mode::StopNewInLoopNest. With -jeandle-pea-loop-cutoff=2, a 3-deep
; nest has max depth = 3 which exceeds the threshold, so processLoop
; (called at top-level on the outer loop) transiently enters
; Mode::StopNewInLoopNest. In that mode, processAllocation refuses to register
; NEW allocations inside the nest — but every other operation continues
; unchanged.
;
; CHECK that the innermost-body alloc (klass = 0x4444) survives in IR
; verbatim, even though the body is otherwise trivial enough that without
; StopNewInLoopNest it would normally be virtualised.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @test_stop_new(i32 %n) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  br label %hdr1

hdr1:
  %i1 = phi i32 [0, %entry], [%inc1, %latch1]
  %c1 = icmp slt i32 %i1, %n
  br i1 %c1, label %body1, label %exit1
body1:
  br label %hdr2
latch1:
  %inc1 = add i32 %i1, 1
  br label %hdr1

hdr2:
  %i2 = phi i32 [0, %body1], [%inc2, %latch2]
  %c2 = icmp slt i32 %i2, %n
  br i1 %c2, label %body2, label %exit2
body2:
  br label %hdr3
latch2:
  %inc2 = add i32 %i2, 1
  br label %hdr2

hdr3:
  %i3 = phi i32 [0, %body2], [%inc3, %latch3]
  %c3 = icmp slt i32 %i3, %n
  br i1 %c3, label %body3, label %exit3
body3:
  ; This alloc is INSIDE the nest at depth 3. With cutoff=2, StopNew is
  ; active. Even though the body is a simple alloc+escape that would
  ; otherwise materialize via materializeAt, here it is REFUSED from
  ; virtualisation entirely so the original invoke survives.
  %inner = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
                  ptr inttoptr (i64 4444 to ptr), i32 16, i1 false)
               to label %ib unwind label %u
ib:
  call void @sink(ptr addrspace(1) %inner)
  br label %latch3
latch3:
  %inc3 = add i32 %i3, 1
  br label %hdr3

exit3:
  br label %latch2
exit2:
  br label %latch1
exit1:
  ret void

u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @test_stop_new
; CHECK: invoke {{.*}}@jeandle.new_instance({{.*}}i64 4444
; CHECK: call void @sink

!java-method-compilation = !{}
