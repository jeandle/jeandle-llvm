; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Loop-body partial escape with field mutation in the body before the escape:
; the object is allocated before the loop, its field is written every iteration
; (loop-variant %i), then it escapes via @sink (case A: flows to latch) and is
; read after the loop. The field-replay at the preheader materialize must be
; correct (initial/default at the preheader; the body's real store updates it
; each iteration). Exactly one allocation.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(ptr addrspace(1))
declare void @ret_use_field(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @test_field_mut_then_escape(i32 %n) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
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
  %s = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  store atomic i32 %i, ptr addrspace(1) %s unordered, align 4
  call void @sink(ptr addrspace(1) %o)
  %i1 = add i32 %i, 1
  br label %loop
exit:
  call void @ret_use_field(ptr addrspace(1) %o)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @test_field_mut_then_escape
; CHECK: invoke hotspotcc{{.*}}@jeandle.new_instance(
; CHECK-NOT: jeandle.new_instance
; The body field store and the escape both use the single materialized pointer.
; CHECK: store atomic i32 %i, ptr addrspace(1)
; CHECK: call void @sink(ptr addrspace(1)
; CHECK: call void @ret_use_field(ptr addrspace(1)

!java-method-compilation = !{}
