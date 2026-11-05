; RUN: opt -jeandle-loop-strip-mining-iter=4 \
; RUN:   -passes='loop-simplify,lcssa,safepoint-strip-mining<strip-mining>,verify<jeandle-safepoint-coverage>,verify' \
; RUN:   -verify-each -S < %s | FileCheck %s

; Target-aware induction-variable widening can leave an i32 Java loop result
; as a truncation of the i64 resume IV. Recreate that truncation on the selected
; outer exit, rather than using an inner-loop value across the new boundary.

declare hotspotcc void @jeandle.safepoint_poll()

define i32 @truncated_exit(i64 noundef %limit) "java-method" {
entry:
  br label %header

header:
  %iv = phi i64 [ 0, %entry ], [ %next, %latch ]
  br label %latch

latch:
  %next = add nuw nsw i64 %iv, 1
  %narrow = trunc i64 %next to i32
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i32 %narrow) ]
  %cond = icmp slt i64 %next, %limit
  br i1 %cond, label %header, label %exit

exit:
  %result = phi i32 [ %narrow, %latch ]
  ret i32 %result
}

; CHECK-LABEL: @truncated_exit(
; CHECK:       exit:
; CHECK-NEXT:    %result = phi i32 [ %outer.iv.exit, %header.outer.latch ]
; CHECK:       header.outer.latch:
; CHECK:         %outer.iv.next = phi i64 [ %next, %latch ]
; CHECK:         %outer.iv.exit = trunc i64 %outer.iv.next to i32

define i32 @guarded_exit(i64 noundef %limit) "java-method" {
entry:
  %enter = icmp sgt i64 %limit, 0
  br i1 %enter, label %preheader, label %zero

preheader:
  br label %header

header:
  %iv = phi i64 [ 0, %preheader ], [ %next, %latch ]
  br label %latch

latch:
  %next = add nuw nsw i64 %iv, 1
  %narrow = trunc i64 %next to i32
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i32 %narrow) ]
  %cond = icmp slt i64 %next, %limit
  br i1 %cond, label %header, label %exit

exit:
  %result = phi i32 [ %narrow, %latch ]
  ret i32 %result

zero:
  ret i32 0
}

; CHECK-LABEL: @guarded_exit(
; CHECK:       exit:
; CHECK-NEXT:    %result = phi i32 [ %outer.iv.exit, %header.outer ]
; CHECK:       header.outer:
; CHECK:         %outer.iv = phi i64
; CHECK:         %outer.iv.exit = trunc i64 %outer.iv to i32

; An unrelated derived exit value is still unsupported.
define i32 @unrelated_exit(i64 noundef %limit) "java-method" {
entry:
  br label %header

header:
  %iv = phi i64 [ 0, %entry ], [ %next, %latch ]
  br label %latch

latch:
  %next = add nuw nsw i64 %iv, 1
  %other = xor i64 %next, 7
  %narrow = trunc i64 %other to i32
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i64 %next) ]
  %cond = icmp slt i64 %next, %limit
  br i1 %cond, label %header, label %exit

exit:
  %result = phi i32 [ %narrow, %latch ]
  ret i32 %result
}

; CHECK-LABEL: @unrelated_exit(
; CHECK-NOT:     outer
; CHECK:         call hotspotcc void @jeandle.safepoint_poll()
; CHECK:         %result = phi i32 [ %narrow, %latch ]
