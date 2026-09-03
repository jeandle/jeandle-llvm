; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s
;
; Two DISTINCT loop-local objects %X and %Y, each allocated in the body and each
; carried across the back-edge by its own header PHI (%px, %py), both escaping
; at the exit. Each must be independently materialized at the back-edge.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @test_148_multi_objects(i32 %n) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  br label %hdr
hdr:
  %i = phi i32 [ 0, %entry ], [ %i1, %latch ]
  %px = phi ptr addrspace(1) [ null, %entry ], [ %X, %latch ]
  %py = phi ptr addrspace(1) [ null, %entry ], [ %Y, %latch ]
  %c = icmp slt i32 %i, %n
  br i1 %c, label %body, label %exit
body:
  %X = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 5555 to ptr), i32 16, i1 false)
          to label %xcont unwind label %u
xcont:
  %Y = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 6666 to ptr), i32 16, i1 false)
          to label %ycont unwind label %u
ycont:
  %sfx = getelementptr inbounds i8, ptr addrspace(1) %X, i64 8
  store atomic i32 %i, ptr addrspace(1) %sfx unordered, align 4
  %sfy = getelementptr inbounds i8, ptr addrspace(1) %Y, i64 8
  store atomic i32 %i, ptr addrspace(1) %sfy unordered, align 4
  br label %latch
latch:
  %i1 = add i32 %i, 1
  br label %hdr
exit:
  call void @sink(ptr addrspace(1) %px)
  call void @sink(ptr addrspace(1) %py)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; Both carried objects survive (materialized), both @sink calls receive real
; pointers, no poison.
; CHECK-LABEL: define void @test_148_multi_objects
; CHECK: call void @sink(ptr addrspace(1) %px)
; CHECK: call void @sink(ptr addrspace(1) %py)
; CHECK-NOT: poison

!java-method-compilation = !{}
