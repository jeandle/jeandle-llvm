; RUN: opt -S -passes=adce -verify-each %s | FileCheck %s

; Java unordered loads need no atomic demotion for ordinary dead code
; elimination. A value required by deoptimization remains live.
declare void @checkpoint()

define void @unused_unordered(ptr %p) {
  %value = load atomic i32, ptr %p unordered, align 4
  ret void
}
; CHECK-LABEL: define void @unused_unordered(
; CHECK-NOT: load
; CHECK: ret void

define void @deopt_live_unordered(ptr %p) {
  %value = load atomic i32, ptr %p unordered, align 4
  call void @checkpoint() [ "deopt"(i32 %value) ]
  ret void
}
; CHECK-LABEL: define void @deopt_live_unordered(
; CHECK: %value = load atomic i32, ptr %p unordered
; CHECK: call void @checkpoint() [ "deopt"(i32 %value) ]
; CHECK: ret void

define void @unused_volatile(ptr %p) {
  %value = load atomic volatile i32, ptr %p unordered, align 4
  ret void
}
; CHECK-LABEL: define void @unused_volatile(
; CHECK: load atomic volatile i32
; CHECK: ret void

define void @unused_acquire(ptr %p) {
  %value = load atomic i32, ptr %p acquire, align 4
  ret void
}
; CHECK-LABEL: define void @unused_acquire(
; CHECK: load atomic i32, ptr %p acquire
; CHECK: ret void
