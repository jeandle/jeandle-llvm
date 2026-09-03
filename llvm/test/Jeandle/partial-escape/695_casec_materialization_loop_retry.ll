; RUN: opt -S -verify-each \
; RUN:   -passes="require<partial-escape-analysis>,partial-escape-transform" \
; RUN:   %s | FileCheck %s --check-prefix=SINGLE
; RUN: opt -S -verify-each \
; RUN:   -passes="partial-escape-iterative,partial-escape-iterative" \
; RUN:   -jeandle-pea-iterations=8 %s | FileCheck %s --check-prefix=REPEAT
; RUN: opt -disable-output -verify-each \
; RUN:   -passes="require<partial-escape-analysis>,partial-escape-transform" \
; RUN:   -jeandle-dump-pea-stats \
; RUN:   -jeandle-pea-analyze-function=casec_before_loop_escape_in_loop \
; RUN:   %s 2>&1 | FileCheck %s --check-prefix=STATS-BEFORE
; RUN: opt -disable-output -verify-each \
; RUN:   -passes="require<partial-escape-analysis>,partial-escape-transform" \
; RUN:   -jeandle-dump-pea-stats \
; RUN:   -jeandle-pea-analyze-function=casec_inside_loop \
; RUN:   %s 2>&1 | FileCheck %s --check-prefix=STATS-INSIDE

; Synthetic identity preparation is monotonic across the loop fixpoint, while
; virtual/materialized state remains path-local.  Loop retries must neither
; lose nor duplicate the one point-local replay emitted at the first escape.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1) nounwind
declare void @sink(ptr addrspace(1))

; The Case-C identity is defined before the loop and first escapes in the loop.
define void @casec_before_loop_escape_in_loop(i1 %choose, i32 %limit)
    gc "hotspotgc" {
entry:
  br i1 %choose, label %left, label %right
left:
  %a = call hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 69501 to ptr), i32 24, i1 false) [ "deopt"(i32 695011) ]
  %af = getelementptr inbounds i8, ptr addrspace(1) %a, i64 8
  store atomic i32 91, ptr addrspace(1) %af unordered, align 4
  br label %preheader
right:
  %b = call hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 69501 to ptr), i32 24, i1 false) [ "deopt"(i32 695012) ]
  %bf = getelementptr inbounds i8, ptr addrspace(1) %b, i64 8
  store atomic i32 92, ptr addrspace(1) %bf unordered, align 4
  br label %preheader
preheader:
  %p = phi ptr addrspace(1) [ %a, %left ], [ %b, %right ]
  %post = getelementptr inbounds i8, ptr addrspace(1) %p, i64 16
  store atomic i32 93, ptr addrspace(1) %post unordered, align 4
  br label %loop
loop:
  %i = phi i32 [ 0, %preheader ], [ %next, %loop ]
  call void @sink(ptr addrspace(1) %p)
  %next = add nuw i32 %i, 1
  %again = icmp ult i32 %next, %limit
  br i1 %again, label %loop, label %exit
exit:
  ret void
}

; SINGLE-LABEL: define void @casec_before_loop_escape_in_loop(
; SINGLE: left:
; SINGLE-NEXT: %a = call hotspotcc ptr addrspace(1) @jeandle.new_instance{{.*}}[ "deopt"(i32 695011) ]
; SINGLE-NOT: store atomic
; SINGLE-NEXT: br label %preheader
; SINGLE: right:
; SINGLE-NEXT: %b = call hotspotcc ptr addrspace(1) @jeandle.new_instance{{.*}}[ "deopt"(i32 695012) ]
; SINGLE-NOT: store atomic
; SINGLE-NEXT: br label %preheader
; SINGLE: preheader:
; SINGLE-NEXT: %p = phi ptr addrspace(1) [ %a, %left ], [ %b, %right ]
; SINGLE-NEXT: %[[FIELD:pea.casec.field.phi[^ ]*]] = phi i32 [ 91, %left ], [ 92, %right ]
; SINGLE-NEXT: %[[SLOT8:pea.matslot[^ ]*]] = getelementptr inbounds i8, ptr addrspace(1) %p, i64 8
; SINGLE-NEXT: store atomic i32 %[[FIELD]], ptr addrspace(1) %[[SLOT8]] unordered, align 4
; SINGLE-NEXT: %[[SLOT16:pea.matslot[^ ]*]] = getelementptr inbounds i8, ptr addrspace(1) %p, i64 16
; SINGLE-NEXT: store atomic i32 93, ptr addrspace(1) %[[SLOT16]] unordered, align 4
; SINGLE-NEXT: br label %loop
; SINGLE: loop:
; SINGLE: call void @sink(ptr addrspace(1) %p)
; SINGLE-NOT: store atomic i32
; SINGLE-NOT: call void @sink
; SINGLE-NOT: poison

; The Case-C definition and its materialization both live inside the loop.  A
; retry must not keep materialized exit state while discarding the point-local
; replay, nor re-emit it with duplicate sequence numbers.
define void @casec_inside_loop(i1 %choose, i32 %limit) gc "hotspotgc" {
entry:
  br label %loop
loop:
  %i = phi i32 [ 0, %entry ], [ %next, %latch ]
  br i1 %choose, label %left, label %right
left:
  %a = call hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 69502 to ptr), i32 16, i1 false) [ "deopt"(i32 695021) ]
  %af = getelementptr inbounds i8, ptr addrspace(1) %a, i64 8
  store atomic i32 101, ptr addrspace(1) %af unordered, align 4
  br label %merge
right:
  %b = call hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 69502 to ptr), i32 16, i1 false) [ "deopt"(i32 695022) ]
  %bf = getelementptr inbounds i8, ptr addrspace(1) %b, i64 8
  store atomic i32 102, ptr addrspace(1) %bf unordered, align 4
  br label %merge
merge:
  %p = phi ptr addrspace(1) [ %a, %left ], [ %b, %right ]
  call void @sink(ptr addrspace(1) %p)
  br label %latch
latch:
  %next = add nuw i32 %i, 1
  %again = icmp ult i32 %next, %limit
  br i1 %again, label %loop, label %exit
exit:
  ret void
}

; SINGLE-LABEL: define void @casec_inside_loop(
; SINGLE: left:
; SINGLE-NEXT: %a = call hotspotcc ptr addrspace(1) @jeandle.new_instance{{.*}}[ "deopt"(i32 695021) ]
; SINGLE-NOT: store atomic
; SINGLE-NEXT: br label %merge
; SINGLE: right:
; SINGLE-NEXT: %b = call hotspotcc ptr addrspace(1) @jeandle.new_instance{{.*}}[ "deopt"(i32 695022) ]
; SINGLE-NOT: store atomic
; SINGLE-NEXT: br label %merge
; SINGLE: merge:
; SINGLE-NEXT: %p = phi ptr addrspace(1) [ %a, %left ], [ %b, %right ]
; SINGLE-NEXT: %[[IFIELD:pea.casec.field.phi[^ ]*]] = phi i32 [ 101, %left ], [ 102, %right ]
; SINGLE-NEXT: %[[ISLOT:pea.matslot[^ ]*]] = getelementptr inbounds i8, ptr addrspace(1) %p, i64 8
; SINGLE-NEXT: store atomic i32 %[[IFIELD]], ptr addrspace(1) %[[ISLOT]] unordered, align 4
; SINGLE-NEXT: call void @sink(ptr addrspace(1) %p)
; SINGLE-NOT: store atomic i32
; SINGLE-NOT: call void @sink
; SINGLE-NOT: poison

; REPEAT-LABEL: define void @casec_before_loop_escape_in_loop(
; REPEAT-NOT: @jeandle.new_instance
; REPEAT: %a = call hotspotcc ptr addrspace(1) @jeandle.new_instance
; REPEAT-NOT: @jeandle.new_instance
; REPEAT-NOT: store atomic i32
; REPEAT: %b = call hotspotcc ptr addrspace(1) @jeandle.new_instance
; REPEAT-NOT: @jeandle.new_instance
; REPEAT-NOT: store atomic i32
; REPEAT: %[[RFIELD:pea.casec.field.phi[^ ]*]] = phi i32 [ 91, %left ], [ 92, %right ]
; REPEAT-NOT: store atomic i32
; REPEAT: store atomic i32 %[[RFIELD]]
; REPEAT-NEXT: %{{.*}} = getelementptr inbounds{{( nuw)?}} i8, ptr addrspace(1) %p, i64 16
; REPEAT-NEXT: store atomic i32 93
; REPEAT-NOT: store atomic i32
; REPEAT: call void @sink
; REPEAT-NOT: @jeandle.new_instance
; REPEAT-NOT: store atomic i32
; REPEAT-NOT: call void @sink
; REPEAT-NOT: poison
; REPEAT-LABEL: define void @casec_inside_loop(
; REPEAT-NOT: @jeandle.new_instance
; REPEAT: %a = call hotspotcc ptr addrspace(1) @jeandle.new_instance
; REPEAT-NOT: @jeandle.new_instance
; REPEAT-NOT: store atomic i32
; REPEAT: %b = call hotspotcc ptr addrspace(1) @jeandle.new_instance
; REPEAT-NOT: @jeandle.new_instance
; REPEAT-NOT: store atomic i32
; REPEAT: %[[RIFIELD:pea.casec.field.phi[^ ]*]] = phi i32 [ 101, %left ], [ 102, %right ]
; REPEAT-NOT: store atomic i32
; REPEAT: store atomic i32 %[[RIFIELD]]
; REPEAT-NOT: store atomic i32
; REPEAT: call void @sink
; REPEAT-NOT: @jeandle.new_instance
; REPEAT-NOT: store atomic i32
; REPEAT-NOT: call void @sink
; REPEAT-NOT: poison
; STATS-BEFORE: PEA stats @casec_before_loop_escape_in_loop: NeverEscapes=0 PartiallyEscapes=2 AlwaysEscapes=0
; STATS-INSIDE: PEA stats @casec_inside_loop: NeverEscapes=0 PartiallyEscapes=2 AlwaysEscapes=0

!java-method-compilation = !{}
