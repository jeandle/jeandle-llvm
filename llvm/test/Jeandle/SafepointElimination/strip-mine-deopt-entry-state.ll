; RUN: opt -passes='loop-simplify,lcssa,safepoint-strip-mining<strip-mining>,safepoint-poll-elimination<after-strip-mining>,verify<jeandle-safepoint-coverage>,verify' \
; RUN:   -jeandle-loop-strip-mining-iter=8 -jeandle-verify-safepoint-coverage=fatal -S < %s | FileCheck %s

; A taken-edge poll becomes a header-entry poll after loop rotation. Its Java
; locals (including a widened IV cast back to int) represent entry state, not
; the preceding batch's final body state. Keep the poll at the per-batch entry
; so a final exit never deopts into an iteration which should not execute.
declare hotspotcc void @jeandle.safepoint_poll()

define i64 @entry_state(i32 noundef %limit) "java-method" {
entry:
  %nonempty = icmp sgt i32 %limit, 1
  br i1 %nonempty, label %preheader, label %exit
preheader:
  %wide.limit = zext i32 %limit to i64
  br label %loop
loop:
  %iv = phi i64 [ 1, %preheader ], [ %iv.next, %loop ]
  %sum = phi i64 [ 0, %preheader ], [ %sum.next, %loop ]
  %count = phi i32 [ 1, %preheader ], [ %count.next, %loop ]
  %local = trunc nuw nsw i64 %iv to i32
  call hotspotcc void @jeandle.safepoint_poll()
      [ "deopt"(i32 22, i32 22, i64 %sum, i32 %count, i32 %local, i32 %limit) ]
  %sum.next = add i64 %sum, %iv
  %count.next = add nuw nsw i32 %count, 1
  %iv.next = add nuw nsw i64 %iv, 1
  %more = icmp ne i64 %iv.next, %wide.limit
  br i1 %more, label %loop, label %exit
exit:
  %result = phi i64 [ 0, %entry ], [ %sum.next, %loop ]
  ret i64 %result
}

; CHECK-LABEL: @entry_state(
; CHECK:       loop:
; CHECK-NOT:     call hotspotcc void @jeandle.safepoint_poll
; CHECK:         %sum.next = add
; CHECK:       loop.outer.inner.entry:
; CHECK:         %local.outer = trunc nuw nsw i64 %outer.iv to i32
; CHECK-NEXT:    call hotspotcc void @jeandle.safepoint_poll() #{{[0-9]+}}
; CHECK-SAME:      [ "deopt"(i32 22, i32 22, i64 %sum.outer, i32 %count.outer, i32 %local.outer, i32 %limit) ]
; CHECK-NEXT:    br label %loop
; CHECK:       loop.outer.latch:
; CHECK-NOT:     call hotspotcc void @jeandle.safepoint_poll
; CHECK:       }

; A swap recurrence must be remapped by phi identity. Mapping a raw entry phi
; through the latch-value lookup would interchange a and b at a batch entry.
define void @entry_swap(i64 noundef %limit) "java-method" {
entry:
  br label %loop
loop:
  %iv = phi i64 [ 0, %entry ], [ %iv.next, %loop ]
  %a = phi i64 [ 1, %entry ], [ %b, %loop ]
  %b = phi i64 [ 2, %entry ], [ %a, %loop ]
  call hotspotcc void @jeandle.safepoint_poll()
      [ "deopt"(i64 %iv, i64 %a, i64 %b) ]
  %iv.next = add i64 %iv, 1
  %more = icmp slt i64 %iv.next, %limit
  br i1 %more, label %loop, label %exit
exit:
  ret void
}

; CHECK-LABEL: @entry_swap(
; CHECK:       loop.outer.inner.entry:
; CHECK:         call hotspotcc void @jeandle.safepoint_poll() #{{[0-9]+}}
; CHECK-SAME:      [ "deopt"(i64 %outer.iv, i64 %a.outer, i64 %b.outer) ]
; CHECK:       loop.outer.latch:
; CHECK-NOT:     call hotspotcc void @jeandle.safepoint_poll
; CHECK:       }

; IndVarSimplify can turn i <= limit into a widened != limit+1 test.
; Apply the dominating entry guard to that expression before proving the
; ordered unit-stride range. A direct implication query misses this shape.
declare i32 @llvm.smin.i32(i32, i32)

define i64 @entry_inclusive(i32 noundef %limit) "java-method" {
entry:
  %cap = call i32 @llvm.smin.i32(i32 %limit, i32 1000000)
  %nonempty = icmp sge i32 %cap, 1
  br i1 %nonempty, label %preheader, label %exit
preheader:
  %end = add nsw i32 %cap, 1
  %wide.limit = zext i32 %end to i64
  br label %loop
loop:
  %iv = phi i64 [ 1, %preheader ], [ %iv.next, %loop ]
  %sum = phi i64 [ 0, %preheader ], [ %sum.next, %loop ]
  %local = trunc nuw nsw i64 %iv to i32
  call hotspotcc void @jeandle.safepoint_poll()
      [ "deopt"(i64 %sum, i32 %local) ]
  %sum.next = add i64 %sum, %iv
  %iv.next = add nuw nsw i64 %iv, 1
  %done = icmp eq i64 %iv.next, %wide.limit
  br i1 %done, label %exit, label %loop
exit:
  %result = phi i64 [ 0, %entry ], [ %sum.next, %loop ]
  ret i64 %result
}

; CHECK-LABEL: @entry_inclusive(
; CHECK:       loop.outer.inner.entry:
; CHECK:         %local.outer = trunc nuw nsw i64 %outer.iv to i32
; CHECK-NEXT:    call hotspotcc void @jeandle.safepoint_poll() #{{[0-9]+}}
; CHECK-SAME:      [ "deopt"(i64 %sum.outer, i32 %local.outer) ]

; Entry state alone is not a proof that a != exit is reachable without wrap.
define void @unproven_ne(i64 noundef %limit) "java-method" {
entry:
  br label %loop
loop:
  %iv = phi i64 [ 1, %entry ], [ %iv.next, %loop ]
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i64 %iv) ]
  %iv.next = add i64 %iv, 1
  %more = icmp ne i64 %iv.next, %limit
  br i1 %more, label %loop, label %exit
exit:
  ret void
}

; CHECK-LABEL: @unproven_ne(
; CHECK-NOT:     .outer
; CHECK:         call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i64 %iv) ]
; CHECK-NOT:     .outer
; CHECK:       }

!java-method-compilation = !{}
