; RUN: opt -S -passes="loop-simplify,require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Same IR shape as test 140 (header with two forward predecessors), but
; with `loop-simplify` scheduled before PEA. LoopSimplify inserts a
; synthetic preheader so PEA's loop fixpoint path runs and the
; alloc-before-loop pattern is fully folded. This is the path the
; Jeandle pipeline takes in production (Pipeline.cpp schedules
; LoopSimplifyPass before PEA).

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @use(i32)
declare i32 @__gxx_personality_v0(...)

define void @test_c6_after_loopsimplify(i1 %p, i32 %n) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %dispatch unwind label %u
dispatch:
  br i1 %p, label %fwd_a, label %fwd_b
fwd_a:
  br label %hdr
fwd_b:
  br label %hdr
hdr:
  %i = phi i32 [ 0, %fwd_a ], [ 0, %fwd_b ], [ %i1, %latch ]
  %c = icmp slt i32 %i, %n
  br i1 %c, label %body, label %exit
body:
  %s = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  store atomic i32 %i, ptr addrspace(1) %s unordered, align 4
  %v = load atomic i32, ptr addrspace(1) %s unordered, align 4
  call void @use(i32 %v)
  br label %latch
latch:
  %i1 = add i32 %i, 1
  br label %hdr
exit:
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; After LoopSimplify canonicalises the entry to the loop, the loop
; fixpoint takes over and folds the alloc + field store/load.
; @use receives %i directly (the in-body store-load forwards through
; processLoad on the virtual field).
; CHECK-LABEL: define void @test_c6_after_loopsimplify
; CHECK-NOT: jeandle.new_instance
; CHECK-NOT: store atomic
; CHECK-NOT: load atomic
; CHECK: call void @use(i32 %i)

!java-method-compilation = !{}
