; RUN: opt -passes='jeandle-check-optimization' -verify-each -S %s | FileCheck %s --check-prefix=FULL
; RUN: opt -passes='loop-simplify,lcssa,jeandle-affine-check-versioning' -verify-each -S %s | FileCheck %s


declare noundef range(i32 0, -2147483648) i32 @jeandle.arraylength(ptr addrspace(1) noundef) nounwind willreturn memory(read)
declare i32 @llvm.experimental.deoptimize.i32(...)
declare void @effect(i32)
declare i32 @handler(i32)

define i32 @scaled(ptr addrspace(1) noundef nonnull %a, i32 noundef %end, i32 noundef %offset) {
; FULL-LABEL: define i32 @scaled(
; FULL: br i1 {{.*}}, label %{{.*}}, label %loop.affine.slow.preheader
; FULL: %ok.affine.slow = icmp ult
; FULL: loop:
; FULL-NOT: icmp ult
; FULL: call void @effect
; FULL: !llvm.loop
; FULL: call i32 @handler(i32 %index.affine.slow.lcssa)
; CHECK-LABEL: define i32 @scaled(
; CHECK: affine.fast
; CHECK: %ok.affine.slow = icmp ult
; CHECK: loop:
; CHECK: br i1 true
entry:
  %length = call i32 @jeandle.arraylength(ptr addrspace(1) %a)
  %enter = icmp sgt i32 %end, 0
  br i1 %enter, label %preheader, label %exit
preheader:
  br label %loop
loop:
  %i = phi i32 [ 0, %preheader ], [ %next, %body ]
  %scaled = mul i32 %i, 3
  %index = add i32 %scaled, %offset
  %ok = icmp ult i32 %index, %length
  br i1 %ok, label %body, label %fail, !prof !0
body:
  call void @effect(i32 %index)
  %next = add i32 %i, 1
  %again = icmp slt i32 %next, %end
  br i1 %again, label %loop, label %exit
fail:
  %r = call i32 @handler(i32 %index)
  ret i32 %r
exit:
  ret i32 42
}
; State reaching the same ordinary handler differs between the two checks.
define i32 @partial_state(i32 noundef %end, i32 noundef %offset, i32 noundef %otheroffset, i32 noundef %scale, i1 %other) {
; CHECK-LABEL: define i32 @partial_state(
; CHECK: affine.fast
; CHECK: %ok.affine.slow = icmp ult
; CHECK: %both.affine.slow = select i1 %other, i1 %ok2.affine.slow, i1 false
; CHECK: loop:
; CHECK: br i1 true
; CHECK: first:
; CHECK: call void @effect(i32 %x)
; CHECK: %both.affine = select i1 %other, i1 true, i1 false
; CHECK: fail:
; CHECK: %bad = phi i32
; CHECK: %partial = phi i32
; CHECK: call i32 @handler(i32 %state)
entry:
  br label %loop
loop:
  %i = phi i32 [ 0, %entry ], [ %next, %body ]
  %sum = phi i32 [ 0, %entry ], [ %newsum, %body ]
  %scaled = mul i32 %i, %scale
  %x = add i32 %scaled, %offset
  call void @effect(i32 %sum)
  %ok = icmp ult i32 %x, 1000
  br i1 %ok, label %first, label %fail
first:
  call void @effect(i32 %x)
  %newsum = add i32 %sum, %x
  %ybase = mul i32 %i, 5
  %y = add i32 %ybase, %otheroffset
  %ok2 = icmp ult i32 %y, 1000
  %both = select i1 %other, i1 %ok2, i1 false
  br i1 %both, label %body, label %fail
body:
  %next = add i32 %i, 1
  %again = icmp slt i32 %next, %end
  br i1 %again, label %loop, label %exit
fail:
  %bad = phi i32 [ %x, %loop ], [ %y, %first ]
  %partial = phi i32 [ %sum, %loop ], [ %newsum, %first ]
  %state = xor i32 %partial, %bad
  %r = call i32 @handler(i32 %state)
  ret i32 %r
exit:
  ret i32 %newsum
}

define i32 @two_loops(ptr addrspace(1) noundef nonnull %a, i32 noundef %end, i32 noundef %offset, i32 noundef range(i32 1, 1024) %scale) {
; CHECK-LABEL: define i32 @two_loops(
; CHECK: loop.affine.check:
; CHECK: second.loop.affine.check:
; CHECK: second.loop.affine.slow:
entry:
  %length = call i32 @jeandle.arraylength(ptr addrspace(1) %a)
  %enter = icmp sgt i32 %end, 0
  br i1 %enter, label %preheader, label %exit
preheader:
  br label %loop
loop:
  %i = phi i32 [ 0, %preheader ], [ %next, %body ]
  %scaled = mul i32 %i, %scale
  %index = add i32 %scaled, %offset
  %ok = icmp ult i32 %index, %length
  br i1 %ok, label %body, label %fail, !prof !0
body:
  call void @effect(i32 %index)
  %next = add i32 %i, 1
  %again = icmp slt i32 %next, %end
  br i1 %again, label %loop, label %exit
fail:
  %r = call i32 (...) @llvm.experimental.deoptimize.i32(i32 -26) [ "deopt"(i32 %i, i32 %index) ]
  ret i32 %r
exit:
  br label %second.preheader
second.preheader:
  br label %second.loop
second.loop:
  %j = phi i32 [ 0, %second.preheader ], [ %jnext, %second.body ]
  %jscaled = mul i32 %j, %scale
  %jindex = add i32 %jscaled, %offset
  %jok = icmp ult i32 %jindex, %length
  br i1 %jok, label %second.body, label %second.fail
second.body:
  call void @effect(i32 %jindex)
  %jnext = add i32 %j, 1
  %jagain = icmp slt i32 %jnext, %end
  br i1 %jagain, label %second.loop, label %second.exit
second.fail:
  %jr = call i32 @handler(i32 %jindex)
  ret i32 %jr
second.exit:
  ret i32 42
}
!0 = !{!"branch_weights", i32 1048575, i32 1}
!java-method-compilation = !{}
