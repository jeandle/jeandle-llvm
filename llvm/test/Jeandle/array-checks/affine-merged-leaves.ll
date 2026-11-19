; RUN: opt -passes='jeandle-check-optimization' -verify-each -S %s | FileCheck %s --check-prefix=FULL
; RUN: opt -passes='loop-simplify,lcssa,jeandle-affine-check-versioning' -verify-each -S %s | FileCheck %s

declare i32 @llvm.experimental.deoptimize.i32(...)
declare void @effect(i32, i32)
declare void @observe(i1)

define i32 @combined_and(i32 noundef %end, i32 noundef %offset, i32 noundef %otheroffset) {
; FULL-LABEL: define i32 @combined_and(
; FULL: br i1 {{.*}}, label %{{.*}}, label %loop.affine.slow.preheader
; FULL: loop.affine.slow:
; FULL: %xok.affine.slow = icmp ult
; FULL: %yok.affine.slow = icmp ult
; FULL: loop:
; FULL-NOT: icmp ult
; FULL: call void @effect
; FULL-NOT: label %fail
; FULL: !llvm.loop
; CHECK-LABEL: define i32 @combined_and(
; CHECK: affine.fast
; CHECK: %both.affine.slow = and i1 %xok.affine.slow, %yok.affine.slow
; CHECK: loop:
; CHECK: %both.affine = and i1 true, true
; CHECK: br i1 %both.affine
entry:
  %enter = icmp sgt i32 %end, 0
  br i1 %enter, label %preheader, label %exit
preheader:
  br label %loop
loop:
  %i = phi i32 [ 0, %preheader ], [ %next, %body ]
  %xbase = mul i32 %i, 3
  %x = add i32 %xbase, %offset
  %ybase = mul i32 %i, 5
  %y = add i32 %ybase, %otheroffset
  %xok = icmp ult i32 %x, 1000
  %yok = icmp ult i32 %y, 1000
  %both = and i1 %xok, %yok
  br i1 %both, label %body, label %fail
body:
  call void @effect(i32 %x, i32 %y)
  %next = add i32 %i, 1
  %again = icmp slt i32 %next, %end
  br i1 %again, label %loop, label %exit
fail:
  %r = call i32 (...) @llvm.experimental.deoptimize.i32(i32 -26) [ "deopt"(i32 %i, i1 %xok, i1 %yok) ]
  ret i32 %r
exit:
  ret i32 42
}

define i32 @logical_and_partial(i32 noundef %end, i32 noundef %offset, i32 noundef %otheroffset, i1 %other) {
; CHECK-LABEL: define i32 @logical_and_partial(
; CHECK: affine.fast
; CHECK: %both.affine.slow = select i1 %other, i1 %xok.affine.slow, i1 false
; CHECK: loop:
; CHECK: %both.affine = select i1 %other, i1 true, i1 false
; CHECK: br i1 %both.affine
; CHECK: call void @observe(i1 %xok)
; CHECK: "deopt"({{.*}}i1 %xok
entry:
  %enter = icmp sgt i32 %end, 0
  br i1 %enter, label %preheader, label %exit
preheader:
  br label %loop
loop:
  %i = phi i32 [ 0, %preheader ], [ %next, %body ]
  %xbase = mul i32 %i, 3
  %x = add i32 %xbase, %offset
  %ybase = mul i32 %i, 5
  %y = add i32 %ybase, %otheroffset
  %xok = icmp ult i32 %x, 1000
  %yok = icmp ult i32 %y, 1000
  %both = select i1 %other, i1 %xok, i1 false
  br i1 %both, label %body, label %fail
body:
  call void @observe(i1 %xok)
  call void @effect(i32 %x, i32 %y)
  %next = add i32 %i, 1
  %again = icmp slt i32 %next, %end
  br i1 %again, label %loop, label %exit
fail:
  %r = call i32 (...) @llvm.experimental.deoptimize.i32(i32 -26) [ "deopt"(i32 %i, i1 %xok, i1 %yok) ]
  ret i32 %r
exit:
  ret i32 42
}

define i32 @inverted_or(i32 noundef %end, i32 noundef %offset, i32 noundef %otheroffset) {
; CHECK-LABEL: define i32 @inverted_or(
; CHECK: affine.fast
; CHECK: %either.affine.slow = or i1 %xfail.affine.slow, %yfail.affine.slow
; CHECK: loop:
; CHECK: %xfail.affine = xor i1 true, true
; CHECK: %yfail.affine = xor i1 true, true
; CHECK: %either.affine = or i1 %xfail.affine, %yfail.affine
entry:
  %enter = icmp sgt i32 %end, 0
  br i1 %enter, label %preheader, label %exit
preheader:
  br label %loop
loop:
  %i = phi i32 [ 0, %preheader ], [ %next, %body ]
  %xbase = mul i32 %i, 3
  %x = add i32 %xbase, %offset
  %ybase = mul i32 %i, 5
  %y = add i32 %ybase, %otheroffset
  %xok = icmp ult i32 %x, 1000
  %yok = icmp ult i32 %y, 1000
  %xfail = xor i1 %xok, true
  %yfail = xor i1 %yok, true
  %either = or i1 %xfail, %yfail
  br i1 %either, label %fail, label %body
body:
  call void @effect(i32 %x, i32 %y)
  %next = add i32 %i, 1
  %again = icmp slt i32 %next, %end
  br i1 %again, label %loop, label %exit
fail:
  %r = call i32 (...) @llvm.experimental.deoptimize.i32(i32 -26) [ "deopt"(i32 %i, i1 %xok, i1 %yok) ]
  ret i32 %r
exit:
  ret i32 42
}

define i32 @power_two_or(i32 noundef %end, i32 noundef %offset, i32 noundef %otheroffset) {
; CHECK-LABEL: define i32 @power_two_or(
; CHECK: affine.fast
; CHECK: %ok.affine.slow = icmp ult i32 %merged.affine.slow, 1024
; CHECK: loop:
; CHECK: br i1 true
entry:
  %enter = icmp sgt i32 %end, 0
  br i1 %enter, label %preheader, label %exit
preheader:
  br label %loop
loop:
  %i = phi i32 [ 0, %preheader ], [ %next, %body ]
  %xbase = mul i32 %i, 3
  %x = add i32 %xbase, %offset
  %ybase = mul i32 %i, 5
  %y = add i32 %ybase, %otheroffset
  %xok = icmp ult i32 %x, 1000
  %yok = icmp ult i32 %y, 1000
  %merged = or i32 %x, %y
  %ok = icmp ult i32 %merged, 1024
  br i1 %ok, label %body, label %fail
body:
  call void @effect(i32 %x, i32 %y)
  %next = add i32 %i, 1
  %again = icmp slt i32 %next, %end
  br i1 %again, label %loop, label %exit
fail:
  %r = call i32 (...) @llvm.experimental.deoptimize.i32(i32 -26) [ "deopt"(i32 %i, i1 %xok, i1 %yok) ]
  ret i32 %r
exit:
  ret i32 42
}

define i32 @non_power_two_or(i32 noundef %end, i32 noundef %offset, i32 noundef %otheroffset) {
; CHECK-LABEL: define i32 @non_power_two_or(
; CHECK-NOT: affine.fast
; CHECK: %ok = icmp ult i32 %merged, 1000
; CHECK: br i1 %ok
entry:
  %enter = icmp sgt i32 %end, 0
  br i1 %enter, label %preheader, label %exit
preheader:
  br label %loop
loop:
  %i = phi i32 [ 0, %preheader ], [ %next, %body ]
  %xbase = mul i32 %i, 3
  %x = add i32 %xbase, %offset
  %ybase = mul i32 %i, 5
  %y = add i32 %ybase, %otheroffset
  %xok = icmp ult i32 %x, 1000
  %yok = icmp ult i32 %y, 1000
  %merged = or i32 %x, %y
  %ok = icmp ult i32 %merged, 1000
  br i1 %ok, label %body, label %fail
body:
  call void @effect(i32 %x, i32 %y)
  %next = add i32 %i, 1
  %again = icmp slt i32 %next, %end
  br i1 %again, label %loop, label %exit
fail:
  %r = call i32 (...) @llvm.experimental.deoptimize.i32(i32 -26) [ "deopt"(i32 %i, i1 %xok, i1 %yok) ]
  ret i32 %r
exit:
  ret i32 42
}

!java-method-compilation = !{}
