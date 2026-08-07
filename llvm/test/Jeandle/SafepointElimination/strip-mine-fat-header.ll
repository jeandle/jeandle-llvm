; RUN: opt -jeandle-loop-strip-mining-iter=4 \
; RUN:   -jeandle-verify-safepoint-coverage=fatal \
; RUN:   -passes='early-cse,instcombine,simplifycfg,loop-mssa(licm<no-allowspeculation>,loop-rotate,licm,indvars),safepoint-poll-elimination<early>,safepoint-strip-mining<strip-mining>,safepoint-poll-elimination<after-strip-mining>,verify<jeandle-safepoint-coverage>,verify' \
; RUN:   -S < %s | FileCheck %s

; Non-speculative LICM can hoist these guaranteed-to-execute invariant header
; computations before rotation considers its duplication budget. A
; noduplicate call cannot be hoisted or cloned, so that loop remains unmined.

declare hotspotcc void @jeandle.safepoint_poll()
declare void @cannot_duplicate() noduplicate

define void @fat_invariant_header(ptr %sink, i64 %limit, i64 %x0, i64 %x1,
                                  i64 %x2, i64 %x3, i64 %x4, i64 %x5,
                                  i64 %x6, i64 %x7) "java-method" {
entry:
  br label %header

header:
  %iv = phi i64 [ 0, %entry ], [ %iv.next, %latch ]
  %h0 = add i64 %x0, %x1
  %h1 = add i64 %x0, %x2
  %h2 = add i64 %x0, %x3
  %h3 = add i64 %x0, %x4
  %h4 = add i64 %x0, %x5
  %h5 = add i64 %x0, %x6
  %h6 = add i64 %x0, %x7
  %h7 = add i64 %x1, %x2
  %h8 = add i64 %x1, %x3
  %h9 = add i64 %x1, %x4
  %h10 = add i64 %x1, %x5
  %h11 = add i64 %x1, %x6
  %h12 = add i64 %x1, %x7
  %h13 = add i64 %x2, %x3
  %h14 = add i64 %x2, %x4
  %h15 = add i64 %x2, %x5
  %h16 = add i64 %x2, %x6
  %h17 = add i64 %x2, %x7
  %cond = icmp slt i64 %iv, %limit
  br i1 %cond, label %body, label %exit

body:
  store volatile i64 %h0, ptr %sink
  store volatile i64 %h1, ptr %sink
  store volatile i64 %h2, ptr %sink
  store volatile i64 %h3, ptr %sink
  store volatile i64 %h4, ptr %sink
  store volatile i64 %h5, ptr %sink
  store volatile i64 %h6, ptr %sink
  store volatile i64 %h7, ptr %sink
  store volatile i64 %h8, ptr %sink
  store volatile i64 %h9, ptr %sink
  store volatile i64 %h10, ptr %sink
  store volatile i64 %h11, ptr %sink
  store volatile i64 %h12, ptr %sink
  store volatile i64 %h13, ptr %sink
  store volatile i64 %h14, ptr %sink
  store volatile i64 %h15, ptr %sink
  store volatile i64 %h16, ptr %sink
  store volatile i64 %h17, ptr %sink
  %iv.next = add nsw i64 %iv, 1
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i64 %iv.next) ]
  br label %latch

latch:
  br label %header

exit:
  ret void
}

; CHECK-LABEL: @fat_invariant_header(
; CHECK:       body.outer:
; CHECK:       body.outer.latch:
; CHECK:         call hotspotcc void @jeandle.safepoint_poll() #{{[0-9]+}}

define void @noduplicate_header(i64 %limit) "java-method" {
entry:
  br label %header

header:
  %iv = phi i64 [ 0, %entry ], [ %iv.next, %latch ]
  call void @cannot_duplicate()
  %cond = icmp slt i64 %iv, %limit
  br i1 %cond, label %body, label %exit

body:
  %iv.next = add nsw i64 %iv, 1
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i64 %iv.next) ]
  br label %latch

latch:
  br label %header

exit:
  ret void
}

; CHECK-LABEL: @noduplicate_header(
; CHECK-NOT:   .outer
; CHECK:       call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i64 %iv.next) ]

!java-method-compilation = !{}
