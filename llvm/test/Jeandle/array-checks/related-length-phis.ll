; RUN: opt -passes='jeandle-array-length-optimization' -verify-each -S %s | FileCheck %s

declare i32 @jeandle.arraylength(ptr addrspace(1)) nounwind
declare void @opaque(ptr addrspace(1))
declare void @may_throw()
declare i32 @__gxx_personality_v0(...)
declare i32 @llvm.experimental.deoptimize.i32(...)

; Each edge supplies the selected receiver's length, even across opaque calls.
; Neither of the unselected receivers needs to be nonnull.
define i32 @correlated_check(ptr addrspace(1) noundef %a, ptr addrspace(1) noundef %b, i1 noundef %which, i32 noundef %index) {
; CHECK-LABEL: define i32 @correlated_check(
; CHECK: %la = call i32 @jeandle.arraylength
; CHECK: %check.a = icmp ult i32 %index, %la
; CHECK: %lb = call i32 @jeandle.arraylength
; CHECK: %check.b = icmp ult i32 %index, %lb
; CHECK: join:
; CHECK: %[[LENGTH:.*]] = phi i32 [ %la, %left.ok ], [ %lb, %right.ok ]
; CHECK: call void @opaque(ptr addrspace(1) %array)
; CHECK-NOT: call i32 @jeandle.arraylength
; CHECK: %check.again = icmp ult i32 %index, %[[LENGTH]]
entry:
  br i1 %which, label %left, label %right
left:
  %la = call i32 @jeandle.arraylength(ptr addrspace(1) noundef %a)
  %check.a = icmp ult i32 %index, %la
  br i1 %check.a, label %left.ok, label %left.fail
left.ok:
  call void @opaque(ptr addrspace(1) %a)
  br label %join
right:
  %lb = call i32 @jeandle.arraylength(ptr addrspace(1) noundef %b)
  %check.b = icmp ult i32 %index, %lb
  br i1 %check.b, label %right.ok, label %right.fail
right.ok:
  call void @opaque(ptr addrspace(1) %b)
  br label %join
join:
  %array = phi ptr addrspace(1) [ %a, %left.ok ], [ %b, %right.ok ]
  call void @opaque(ptr addrspace(1) %array)
  %again = call i32 @jeandle.arraylength(ptr addrspace(1) noundef %array)
  %check.again = icmp ult i32 %index, %again
  br i1 %check.again, label %ok, label %fail
ok:
  ret i32 %again
left.fail:
  %rl = call i32 (...) @llvm.experimental.deoptimize.i32(i32 -26) [ "deopt"(ptr addrspace(1) %a) ]
  ret i32 %rl
right.fail:
  %rr = call i32 (...) @llvm.experimental.deoptimize.i32(i32 -26) [ "deopt"(ptr addrspace(1) %b) ]
  ret i32 %rr
fail:
  %r = call i32 (...) @llvm.experimental.deoptimize.i32(i32 -26) [ "deopt"(ptr addrspace(1) %array) ]
  ret i32 %r
}

; Translation can encounter another receiver PHI further up the CFG.
define i32 @nested_phis(ptr addrspace(1) noundef %a, ptr addrspace(1) noundef %b, ptr addrspace(1) noundef %c, i1 %which, i1 %other) {
; CHECK-LABEL: define i32 @nested_phis(
; CHECK: %la = call i32 @jeandle.arraylength
; CHECK: %lb = call i32 @jeandle.arraylength
; CHECK: ab:
; CHECK: phi i32
; CHECK: %lc = call i32 @jeandle.arraylength
; CHECK: join:
; CHECK: %[[LENGTH:.*]] = phi i32
; CHECK-NOT: call i32 @jeandle.arraylength
; CHECK: ret i32 %[[LENGTH]]
entry:
  br i1 %other, label %choose, label %third
choose:
  br i1 %which, label %left, label %right
left:
  %la = call i32 @jeandle.arraylength(ptr addrspace(1) noundef %a)
  br label %ab
right:
  %lb = call i32 @jeandle.arraylength(ptr addrspace(1) noundef %b)
  br label %ab
ab:
  %first = phi ptr addrspace(1) [ %a, %left ], [ %b, %right ]
  call void @opaque(ptr addrspace(1) %first)
  br label %join
third:
  %lc = call i32 @jeandle.arraylength(ptr addrspace(1) noundef %c)
  br label %join
join:
  %array = phi ptr addrspace(1) [ %first, %ab ], [ %c, %third ]
  %again = call i32 @jeandle.arraylength(ptr addrspace(1) noundef %array)
  ret i32 %again
}

define i32 @missing_incoming(ptr addrspace(1) noundef %a, ptr addrspace(1) noundef %b, i1 %which) {
; CHECK-LABEL: define i32 @missing_incoming(
; CHECK: join:
; CHECK-NOT: phi i32
; CHECK: %again = call i32 @jeandle.arraylength(ptr addrspace(1) noundef %array)
; CHECK-NEXT: ret i32 %again
entry:
  br i1 %which, label %left, label %right
left:
  %la = call i32 @jeandle.arraylength(ptr addrspace(1) noundef %a)
  br label %join
right:
  call void @opaque(ptr addrspace(1) %b)
  br label %join
join:
  %array = phi ptr addrspace(1) [ %a, %left ], [ %b, %right ]
  %again = call i32 @jeandle.arraylength(ptr addrspace(1) noundef %array)
  ret i32 %again
}

define i32 @wrong_incoming(ptr addrspace(1) noundef %a, ptr addrspace(1) noundef %b, i1 %which) {
; CHECK-LABEL: define i32 @wrong_incoming(
; CHECK: join:
; CHECK-NOT: phi i32
; CHECK: %again = call i32 @jeandle.arraylength(ptr addrspace(1) noundef %array)
entry:
  br i1 %which, label %left, label %right
left:
  %la = call i32 @jeandle.arraylength(ptr addrspace(1) noundef %a)
  br label %join
right:
  %lb = call i32 @jeandle.arraylength(ptr addrspace(1) noundef %a)
  br label %join
join:
  %array = phi ptr addrspace(1) [ %a, %left ], [ %b, %right ]
  %again = call i32 @jeandle.arraylength(ptr addrspace(1) noundef %array)
  ret i32 %again
}

; Independent freezes of potentially undefined receivers are not identities.
define i32 @independent_freezes(ptr addrspace(1) %a, ptr addrspace(1) %b, i1 %which) {
; CHECK-LABEL: define i32 @independent_freezes(
; CHECK: join:
; CHECK-NOT: phi i32
; CHECK: %frozen = freeze ptr addrspace(1) %array
; CHECK-NEXT: %again = call i32 @jeandle.arraylength
entry:
  br i1 %which, label %left, label %right
left:
  %fa = freeze ptr addrspace(1) %a
  %la = call i32 @jeandle.arraylength(ptr addrspace(1) noundef %fa)
  br label %join
right:
  %fb = freeze ptr addrspace(1) %b
  %lb = call i32 @jeandle.arraylength(ptr addrspace(1) noundef %fb)
  br label %join
join:
  %array = phi ptr addrspace(1) [ %a, %left ], [ %b, %right ]
  %frozen = freeze ptr addrspace(1) %array
  %again = call i32 @jeandle.arraylength(ptr addrspace(1) noundef %frozen)
  ret i32 %again
}

; An unreachable predecessor is rejected rather than supplying undef.
define i32 @dead_predecessor(ptr addrspace(1) noundef %a, ptr addrspace(1) noundef %b, i1 %which) {
; CHECK-LABEL: define i32 @dead_predecessor(
; CHECK: join:
; CHECK-NOT: phi i32
; CHECK: %again = call i32 @jeandle.arraylength
entry:
  br i1 %which, label %left, label %right
left:
  %la = call i32 @jeandle.arraylength(ptr addrspace(1) noundef %a)
  br label %join
right:
  %lb = call i32 @jeandle.arraylength(ptr addrspace(1) noundef %b)
  br label %join
dead:
  br label %join
join:
  %array = phi ptr addrspace(1) [ %a, %left ], [ %b, %right ], [ %a, %dead ]
  %again = call i32 @jeandle.arraylength(ptr addrspace(1) noundef %array)
  ret i32 %again
}

; A shared predecessor cannot represent two different receivers in one
; SSAUpdater variable, even when it has read both lengths.
define i32 @conflicting_translations(ptr addrspace(1) noundef %a, ptr addrspace(1) noundef %b, i1 %which) {
; CHECK-LABEL: define i32 @conflicting_translations(
; CHECK: %la = call i32 @jeandle.arraylength
; CHECK: %lb = call i32 @jeandle.arraylength
; CHECK: join:
; CHECK-NOT: phi i32
; CHECK: %again = call i32 @jeandle.arraylength
entry:
  %la = call i32 @jeandle.arraylength(ptr addrspace(1) noundef %a)
  %lb = call i32 @jeandle.arraylength(ptr addrspace(1) noundef %b)
  br i1 %which, label %left, label %right
left:
  br label %join
right:
  br label %join
join:
  %array = phi ptr addrspace(1) [ %a, %left ], [ %b, %right ]
  %again = call i32 @jeandle.arraylength(ptr addrspace(1) noundef %array)
  ret i32 %again
}

define i32 @undefined_sources(ptr addrspace(1) %a, ptr addrspace(1) %b, i1 %which) {
; CHECK-LABEL: define i32 @undefined_sources(
; CHECK: join:
; CHECK-NOT: phi i32
; CHECK: %again = call i32 @jeandle.arraylength
entry:
  br i1 %which, label %left, label %right
left:
  %la = call i32 @jeandle.arraylength(ptr addrspace(1) %a)
  br label %join
right:
  %lb = call i32 @jeandle.arraylength(ptr addrspace(1) %b)
  br label %join
join:
  %array = phi ptr addrspace(1) [ %a, %left ], [ %b, %right ]
  %again = call i32 @jeandle.arraylength(ptr addrspace(1) noundef %array)
  ret i32 %again
}

define i32 @eh_incoming(ptr addrspace(1) noundef %a, ptr addrspace(1) noundef %b) personality ptr @__gxx_personality_v0 {
; CHECK-LABEL: define i32 @eh_incoming(
; CHECK: handler:
; CHECK: landingpad
; CHECK: %lb = call i32 @jeandle.arraylength
; CHECK: join:
; CHECK-NOT: phi i32
; CHECK: %again = call i32 @jeandle.arraylength
entry:
  invoke void @may_throw() to label %left unwind label %handler
left:
  %la = call i32 @jeandle.arraylength(ptr addrspace(1) noundef %a)
  br label %join
handler:
  %exception = landingpad { ptr, i32 } cleanup
  %lb = call i32 @jeandle.arraylength(ptr addrspace(1) noundef %b)
  br label %join
join:
  %array = phi ptr addrspace(1) [ %a, %left ], [ %b, %handler ]
  %again = call i32 @jeandle.arraylength(ptr addrspace(1) noundef %array)
  ret i32 %again
}

!java-method-compilation = !{}
