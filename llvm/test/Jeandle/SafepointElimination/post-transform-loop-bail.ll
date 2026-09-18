; RUN: opt -passes='safepoint-poll-elimination<early>' -S < %s \
; RUN:   | FileCheck %s
; RUN: opt -passes='safepoint-poll-elimination<post-transform>' -S < %s \
; RUN:   | FileCheck %s

; An acyclic poll chain is present alongside a still-cyclic loop. The common
; Early implementation must prove the chain locally without treating the
; unrelated loop as coverage. Both chain arms are independent of the loop.

declare hotspotcc void @jeandle.safepoint_poll()

define void @post_transform_preserves_chain_with_loop(i1 %take_loop)
    "java-method" gc "post-transform-loop-bail" {
entry:
  br i1 %take_loop, label %loop, label %chain

chain:
  call hotspotcc void @jeandle.safepoint_poll()
  br label %chain.next

chain.next:
  call hotspotcc void @jeandle.safepoint_poll()
  br label %exit

loop:
  %iv = phi i32 [ 0, %entry ], [ %iv.next, %loop ]
  %iv.next = add i32 %iv, 1
  call hotspotcc void @jeandle.safepoint_poll()
  %again = icmp slt i32 %iv.next, 4
  br i1 %again, label %loop, label %exit

exit:
  ret void
}

!java-method-compilation = !{}


define void @branch_merge_chain(i1 %take_left) "java-method" gc "branch-merge-chain" {
entry:
  br label %first

first:
  call hotspotcc void @jeandle.safepoint_poll()
  br i1 %take_left, label %left, label %right
left:
  br label %join
right:
  br label %join
join:
  call hotspotcc void @jeandle.safepoint_poll()
  ret void
}

; CHECK-LABEL: @post_transform_preserves_chain_with_loop(
; CHECK:       chain:
; CHECK-NOT:    call hotspotcc void @jeandle.safepoint_poll()
; CHECK:       chain.next:
; CHECK-NEXT:    call hotspotcc void @jeandle.safepoint_poll()



define void @branch_bypass_chain(i1 %take_left) "java-method" gc "branch-bypass-chain" {
entry:
  br label %first

first:
  call hotspotcc void @jeandle.safepoint_poll()
  br i1 %take_left, label %left, label %right
left:
  br label %join
right:
  ret void
join:
  call hotspotcc void @jeandle.safepoint_poll()
  ret void
}

; CHECK-LABEL: @branch_merge_chain(
; CHECK:       first:
; CHECK-NOT:    call hotspotcc void @jeandle.safepoint_poll()
; CHECK:       join:
; CHECK-NEXT:    call hotspotcc void @jeandle.safepoint_poll()

; CHECK-LABEL: @branch_bypass_chain(
; CHECK:       first:
; CHECK-NEXT:    call hotspotcc void @jeandle.safepoint_poll()
; CHECK:       join:
; CHECK-NEXT:    call hotspotcc void @jeandle.safepoint_poll()
