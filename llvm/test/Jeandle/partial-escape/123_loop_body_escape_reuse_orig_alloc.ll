; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; A pre-loop allocation escapes through @sink in the loop body. The normal
; B/B' fixpoint classifies it PartiallyEscapes, retains OrigAlloc %o, and uses
; that dominating receiver on every iteration. This test does not force the
; MaterializeAll fallback.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @test_loop_body_escape_reuse_orig_alloc(i32 %n) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %prep unwind label %u
prep:
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

; OrigAlloc is the only allocation and @sink consumes it directly.
; CHECK-LABEL: define void @test_loop_body_escape_reuse_orig_alloc
; CHECK: %o = invoke {{.*}}@jeandle.new_instance
; CHECK-NOT: @jeandle.new_instance
; CHECK: call void @sink(ptr addrspace(1) %o)

!java-method-compilation = !{}
