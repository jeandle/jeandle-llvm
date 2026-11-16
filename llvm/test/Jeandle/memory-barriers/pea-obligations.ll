; RUN: opt -S -verify-each -passes='partial-escape-iterative' -jeandle-pea-iterations=8 %s | FileCheck %s
; RUN: opt -S -verify-each -passes='require<partial-escape-analysis>,partial-escape-transform' %s | FileCheck %s
; RUN: opt -S -verify-each -passes='require<partial-escape-analysis>,partial-escape-transform' %s | FileCheck %s --check-prefix=CASEC
; Object-owned barriers survive barrier-only replay and merge, while a local
; object's barriers disappear. Global fences retain their independent effect.
target datalayout = "e-p:64:64"
declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare hotspotcc void @jeandle.membar_constructor_freeze(ptr addrspace(1))
declare hotspotcc void @jeandle.membar_clone_source(ptr addrspace(1))
declare hotspotcc void @jeandle.membar_cpuorder()
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

; CHECK-LABEL: define void @barrier_only(
; CHECK: call hotspotcc void @jeandle.membar_constructor_freeze(ptr addrspace(1) %object)
; CHECK-NEXT: call hotspotcc void @jeandle.membar_clone_source(ptr addrspace(1) %object)
; CHECK-NEXT: call void @sink(ptr addrspace(1) %object)
define void @barrier_only() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %object = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 23456 to ptr), i32 24, i1 false) to label %init unwind label %unwind
init:
  call hotspotcc void @jeandle.membar_constructor_freeze(ptr addrspace(1) %object)
  call hotspotcc void @jeandle.membar_clone_source(ptr addrspace(1) %object)
  call void @sink(ptr addrspace(1) %object)
  ret void
unwind:
  %ex = landingpad i64 cleanup
  resume i64 %ex
}

; CHECK-LABEL: define void @local(
; CHECK-NOT: @jeandle.new_instance
; CHECK-NOT: @jeandle.membar_constructor_freeze
; CHECK-NOT: @jeandle.membar_clone_source
; CHECK: call hotspotcc void @jeandle.membar_cpuorder()
; CHECK-NEXT: ret void
define void @local() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %object = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 23456 to ptr), i32 24, i1 false) to label %init unwind label %unwind
init:
  call hotspotcc void @jeandle.membar_constructor_freeze(ptr addrspace(1) %object)
  call hotspotcc void @jeandle.membar_clone_source(ptr addrspace(1) %object)
  call hotspotcc void @jeandle.membar_cpuorder()
  ret void
unwind:
  %ex = landingpad i64 cleanup
  resume i64 %ex
}

; CHECK-LABEL: define void @merged(
; CHECK: call hotspotcc void @jeandle.membar_constructor_freeze(ptr addrspace(1) %object)
; CHECK-NEXT: call hotspotcc void @jeandle.membar_clone_source(ptr addrspace(1) %object)
; CHECK-NEXT: call void @sink(ptr addrspace(1) %object)
define void @merged(i1 %cond) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %object = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 23456 to ptr), i32 24, i1 false) to label %init unwind label %unwind
init:
  br i1 %cond, label %left, label %right
left:
  call hotspotcc void @jeandle.membar_constructor_freeze(ptr addrspace(1) %object)
  br label %join
right:
  call hotspotcc void @jeandle.membar_clone_source(ptr addrspace(1) %object)
  br label %join
join:
  call void @sink(ptr addrspace(1) %object)
  ret void
unwind:
  %ex = landingpad i64 cleanup
  resume i64 %ex
}


; CHECK-LABEL: define void @loop_pending(
; CHECK: call hotspotcc void @jeandle.membar_constructor_freeze(ptr addrspace(1) %object)
; CHECK-NEXT: call hotspotcc void @jeandle.membar_clone_source(ptr addrspace(1) %object)
; CHECK-NEXT: call void @sink(ptr addrspace(1) %object)
define void @loop_pending(i32 %limit) gc "hotspotgc" {
entry:
  %object = call hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 23456 to ptr), i32 24, i1 false)
  call hotspotcc void @jeandle.membar_constructor_freeze(ptr addrspace(1) %object)
  br label %loop
loop:
  %i = phi i32 [ 0, %entry ], [ %next, %body ]
  %again = icmp ult i32 %i, %limit
  br i1 %again, label %body, label %exit
body:
  call hotspotcc void @jeandle.membar_clone_source(ptr addrspace(1) %object)
  %next = add nuw i32 %i, 1
  br label %loop
exit:
  call void @sink(ptr addrspace(1) %object)
  ret void
}

; CHECK-LABEL: define void @synthetic_pending(
; CASEC-LABEL: define void @synthetic_pending(
; CASEC: %identity = phi ptr addrspace(1)
; CASEC-NEXT: call hotspotcc void @jeandle.membar_constructor_freeze(ptr addrspace(1) %identity)
; CHECK: call hotspotcc void @jeandle.membar_constructor_freeze(ptr addrspace(1) %[[RECEIVER:[a-zA-Z.]+]])
; CHECK-NEXT: call hotspotcc void @jeandle.membar_clone_source(ptr addrspace(1) %[[RECEIVER]])
; CHECK-NEXT: call void @sink(ptr addrspace(1) %[[RECEIVER]])
define void @synthetic_pending(i1 %cond) gc "hotspotgc" {
entry:
  br i1 %cond, label %left, label %right
left:
  %a = call hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 23456 to ptr), i32 24, i1 false)
  call hotspotcc void @jeandle.membar_constructor_freeze(ptr addrspace(1) %a)
  br label %join
right:
  %b = call hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 23456 to ptr), i32 24, i1 false)
  call hotspotcc void @jeandle.membar_clone_source(ptr addrspace(1) %b)
  br label %join
join:
  %identity = phi ptr addrspace(1) [ %a, %left ], [ %b, %right ]
  call void @sink(ptr addrspace(1) %identity)
  ret void
}

; CHECK-LABEL: define void @real_receivers(
; CHECK: call hotspotcc void @jeandle.membar_constructor_freeze(ptr addrspace(1) %real)
; CHECK-NEXT: call hotspotcc void @jeandle.membar_clone_source(ptr addrspace(1) null)
; CHECK: %object = call hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK: call hotspotcc void @jeandle.membar_constructor_freeze(ptr addrspace(1) {{(nonnull )?}}%derived)
define void @real_receivers(ptr addrspace(1) %real) gc "hotspotgc" {
entry:
  call hotspotcc void @jeandle.membar_constructor_freeze(ptr addrspace(1) %real)
  call hotspotcc void @jeandle.membar_clone_source(ptr addrspace(1) null)
  %object = call hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 23456 to ptr), i32 24, i1 false)
  %derived = getelementptr inbounds i8, ptr addrspace(1) %object, i64 16
  call hotspotcc void @jeandle.membar_constructor_freeze(ptr addrspace(1) %derived)
  ret void
}
!java-method-compilation = !{}
