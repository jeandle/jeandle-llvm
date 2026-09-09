; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; PEA: an object is allocated in `entry`, a field is stored in
; `prep`, then a loop iterates and uses the object via @sink on each
; iteration. PEA retains the source allocation and replays the tracked field
; before the first escape; the loop uses the same dominating OrigAlloc.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @test_obj_into_loop(i32 %n) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %prep unwind label %u
prep:
  %s = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  store atomic i32 99, ptr addrspace(1) %s unordered, align 4
  br label %loop
loop:
  %i = phi i32 [ 0, %prep ], [ %i1, %body ]
  %c = icmp slt i32 %i, %n
  br i1 %c, label %body, label %exit
body:
  call void @sink(ptr addrspace(1) %o)
  %i1 = add i32 %i, 1
  br label %loop
exit:
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; The source allocation is the only invoke. Its field is replayed and @sink
; receives the same %o pointer.
; CHECK-LABEL: define void @test_obj_into_loop
; CHECK: %o = invoke {{.*}}@jeandle.new_instance
; CHECK-NOT: @jeandle.new_instance
; CHECK: store atomic i32 99
; CHECK: call void @sink(ptr addrspace(1) %o)

!java-method-compilation = !{}
