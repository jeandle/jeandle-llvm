; RUN: opt < %s -passes=bit-shuffle-folding -verify-each -S | FileCheck %s

; Check revisits within a single pass, without InstCombine or a second pass
; repairing missed folds. The last call is visited first by the worklist.

declare i32 @llvm.x86.bmi.pext.32(i32, i32)
declare i32 @llvm.x86.bmi.pdep.32(i32, i32)
declare i64 @llvm.x86.bmi.pext.64(i64, i64)
declare i64 @llvm.x86.bmi.pdep.64(i64, i64)

; Deleting an unused call leaves the shift mask with one use.
define i32 @single_use_mask(i32 %x, i32 %s) {
; CHECK-LABEL: @single_use_mask(
; CHECK-NEXT: %[[SHIFT:.*]] = lshr i32 %x, %s
; CHECK-NEXT: %[[R:.*]] = and i32 %[[SHIFT]], 1
; CHECK-NEXT: ret i32 %[[R]]
  %mask = shl i32 1, %s
  %dead = call i32 @llvm.x86.bmi.pdep.32(i32 -1, i32 %mask)
  %r = call i32 @llvm.x86.bmi.pext.32(i32 %x, i32 %mask)
  ret i32 %r
}

; The surviving consumer must be revisited after both uses in %twice are
; dropped, rather than inspecting use counts inside the deletion callback.
define i64 @recursive_repeated_mask(i64 %x, i64 %s) {
; CHECK-LABEL: @recursive_repeated_mask(
; CHECK-NEXT: %[[R:.*]] = shl i64 %x, %s
; CHECK-NEXT: ret i64 %[[R]]
  %mask = shl i64 -1, %s
  %twice = add i64 %mask, %mask
  %dead = call i64 @llvm.x86.bmi.pdep.64(i64 -1, i64 %twice)
  %r = call i64 @llvm.x86.bmi.pdep.64(i64 %x, i64 %mask)
  ret i64 %r
}

; Recursive deletion exposes a single-use inner inverse call.
define i32 @single_use_inner(i32 %x, i32 %m) {
; CHECK-LABEL: @single_use_inner(
; CHECK-NEXT: %[[R:.*]] = and i32 %x, %m
; CHECK-NEXT: ret i32 %[[R]]
  %inner = call i32 @llvm.x86.bmi.pext.32(i32 %x, i32 %m)
  %twice = add i32 %inner, %inner
  %dead = call i32 @llvm.x86.bmi.pdep.32(i32 -1, i32 %twice)
  %r = call i32 @llvm.x86.bmi.pdep.32(i32 %inner, i32 %m)
  ret i32 %r
}

define i64 @single_use_inner_reverse(i64 %x, i64 %m) {
; CHECK-LABEL: @single_use_inner_reverse(
; CHECK-NEXT: %[[F:.*]] = freeze i64 %m
; CHECK-NEXT: %[[M:.*]] = call i64 @llvm.x86.bmi.pext.64(i64 %[[F]], i64 %[[F]])
; CHECK-NEXT: %[[R:.*]] = and i64 %x, %[[M]]
; CHECK-NEXT: ret i64 %[[R]]
  %inner = call i64 @llvm.x86.bmi.pdep.64(i64 %x, i64 %m)
  %dead = call i64 @llvm.x86.bmi.pdep.64(i64 -1, i64 %inner)
  %r = call i64 @llvm.x86.bmi.pext.64(i64 %inner, i64 %m)
  ret i64 %r
}

; A replacement changes an already visited user's mask and also exposes a
; single-use producer. Both notifications refer to the same pending call.
define i64 @replacement_user(i64 %x, i64 %s) {
; CHECK-LABEL: @replacement_user(
; CHECK-NEXT: %[[SHIFT:.*]] = lshr i64 %x, %s
; CHECK-NEXT: %[[R:.*]] = and i64 %[[SHIFT]], 1
; CHECK-NEXT: ret i64 %[[R]]
  %mask = shl i64 1, %s
  %a = call i64 @llvm.x86.bmi.pdep.64(i64 -1, i64 %mask)
  %r = call i64 @llvm.x86.bmi.pext.64(i64 %x, i64 %a)
  ret i64 %r
}

; Recursively deleted calls may still be waiting in the worklist.
define i32 @deleted_pending_call(i32 %x, i32 %m) {
; CHECK-LABEL: @deleted_pending_call(
; CHECK-NEXT: ret i32 %x
  %inner = call i32 @llvm.x86.bmi.pext.32(i32 %x, i32 %m)
  %twice = add i32 %inner, %inner
  %dead = call i32 @llvm.x86.bmi.pdep.32(i32 -1, i32 %twice)
  ret i32 %x
}

!java-method-compilation = !{}
