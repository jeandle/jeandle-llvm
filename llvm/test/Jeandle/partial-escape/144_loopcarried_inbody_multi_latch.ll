; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s
;
; Multi-latch loop: the header has TWO back-edge predecessors (latch1, latch2).
; A loop-LOCAL object %X allocated in the body is carried across BOTH back-edges
; by the header PHI %px and escapes at the exit. Jeandle materializes at each
; back-edge pred's end (per-pred loop): the post-body merge Case A must
; materialize at BOTH latches.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @test_144_multi_latch(i1 %cond, i32 %n) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  br label %hdr
hdr:
  %i = phi i32 [ 0, %entry ], [ %i1, %latch1 ], [ %i2, %latch2 ]
  %px = phi ptr addrspace(1) [ null, %entry ], [ %X, %latch1 ], [ %X, %latch2 ]
  %c = icmp slt i32 %i, %n
  br i1 %c, label %body, label %exit
body:
  %X = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 5555 to ptr), i32 16, i1 false)
          to label %bcont unwind label %u
bcont:
  %sf = getelementptr inbounds i8, ptr addrspace(1) %X, i64 8
  store atomic i32 %i, ptr addrspace(1) %sf unordered, align 4
  br i1 %cond, label %latch1, label %latch2
latch1:
  %i1 = add i32 %i, 1
  br label %hdr
latch2:
  %i2 = add i32 %i, 2
  br label %hdr
exit:
  %ec = icmp eq ptr addrspace(1) %px, null
  br i1 %ec, label %done, label %obs
obs:
  call void @sink(ptr addrspace(1) %px)
  br label %done
done:
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; The carried object is materialized (PartiallyEscapes), no poison, and the exit
; @sink receives the carried pointer. Both back-edges are handled.
; CHECK-LABEL: define void @test_144_multi_latch
; CHECK: call void @sink(ptr addrspace(1) %px)
; CHECK-NOT: poison

!java-method-compilation = !{}
