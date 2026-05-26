; RUN: opt -passes=safepoint-elimination -S < %s | FileCheck %s

; A loop testing the IV with `icmp ne` while stepping by 2. The IV starts at 0
; and only equals %n if %n is even — for odd %n the loop runs forever. The
; pass refuses to drop the safepoint when |stride| != 1 and the predicate is
; eq/ne.

declare hotspotcc void @jeandle.safepoint_poll()

define void @bad_predicate_ne(i32 %n) gc "bad-predicate-ne" {
entry:
  br label %loop.header

loop.header:
  %iv = phi i32 [ 0, %entry ], [ %iv.next, %loop.latch ]
  %exit.cond = icmp ne i32 %iv, %n
  br i1 %exit.cond, label %loop.body, label %exit

loop.body:
  call hotspotcc void @jeandle.safepoint_poll()
  br label %loop.latch

loop.latch:
  %iv.next = add nsw i32 %iv, 2
  br label %loop.header

exit:
  call hotspotcc void @jeandle.safepoint_poll()
  ret void
}

!java-method-compilation = !{}

; CHECK-LABEL: @bad_predicate_ne(
; CHECK:       loop.body:
; CHECK-NEXT:    call hotspotcc void @jeandle.safepoint_poll()
; CHECK:       {{^exit:}}
; CHECK-NEXT:    call hotspotcc void @jeandle.safepoint_poll()
; CHECK-NEXT:    ret void
