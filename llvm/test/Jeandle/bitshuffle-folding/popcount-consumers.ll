; RUN: opt -S -verify-each -passes='bit-shuffle-folding,instcombine' %s | FileCheck %s
; RUN: opt -S -verify-each -passes='bit-shuffle-folding,bit-shuffle-folding,instcombine' %s | FileCheck %s

!java-method-compilation = !{}

declare i32 @llvm.ctpop.i32(i32)
declare i64 @llvm.ctpop.i64(i64)
declare i32 @llvm.x86.bmi.pext.32(i32, i32)
declare i64 @llvm.x86.bmi.pext.64(i64, i64)
declare i32 @llvm.x86.bmi.pdep.32(i32, i32)

; The extracted bits are exactly the masked bits, so popcount of a
; compress is popcount of the masked input.
define i32 @popcount_compress_32(i32 %x, i32 %m) {
; CHECK-LABEL: @popcount_compress_32(
; CHECK-NOT: pext
; CHECK: %[[AND:.*]] = and i32 %x, %m
; CHECK: %[[CNT:.*]] = call{{.*}} i32 @llvm.ctpop.i32(i32 %[[AND]])
; CHECK: ret i32 %[[CNT]]
  %c = call i32 @llvm.x86.bmi.pext.32(i32 %x, i32 %m)
  %p = call i32 @llvm.ctpop.i32(i32 %c)
  ret i32 %p
}

define i64 @popcount_compress_64(i64 %x, i64 %m) {
; CHECK-LABEL: @popcount_compress_64(
; CHECK-NOT: pext
; CHECK: %[[AND:.*]] = and i64 %x, %m
; CHECK: %[[CNT:.*]] = call{{.*}} i64 @llvm.ctpop.i64(i64 %[[AND]])
; CHECK: ret i64 %[[CNT]]
  %c = call i64 @llvm.x86.bmi.pext.64(i64 %x, i64 %m)
  %p = call i64 @llvm.ctpop.i64(i64 %c)
  ret i64 %p
}

; The compress result keeps its other user; only the popcount input is
; rewritten.
define i32 @popcount_compress_multiuse(i32 %x, i32 %m, ptr %p) {
; CHECK-LABEL: @popcount_compress_multiuse(
; CHECK: %[[C:.*]] = call i32 @llvm.x86.bmi.pext.32(i32 %x, i32 %m)
; CHECK: store i32 %[[C]], ptr %p
; CHECK: %[[AND:.*]] = and i32 %x, %m
; CHECK: %[[CNT:.*]] = call{{.*}} i32 @llvm.ctpop.i32(i32 %[[AND]])
  %c = call i32 @llvm.x86.bmi.pext.32(i32 %x, i32 %m)
  store i32 %c, ptr %p
  %q = call i32 @llvm.ctpop.i32(i32 %c)
  ret i32 %q
}

; popcount(expand(x, m)) counts the low popcount(m) bits of x, not the
; masked bits, so no rewrite applies.
define i32 @popcount_expand_not_folded(i32 %x, i32 %m) {
; CHECK-LABEL: @popcount_expand_not_folded(
; CHECK: %[[D:.*]] = call i32 @llvm.x86.bmi.pdep.32(i32 %x, i32 %m)
; CHECK: %[[CNT:.*]] = call{{.*}} i32 @llvm.ctpop.i32(i32 %[[D]])
; CHECK: ret i32 %[[CNT]]
  %d = call i32 @llvm.x86.bmi.pdep.32(i32 %x, i32 %m)
  %p = call i32 @llvm.ctpop.i32(i32 %d)
  ret i32 %p
}

; A popcount of an and that this pass produced from a low-mask compress is
; already optimal; running the fold twice must be stable.
define i32 @low_mask_idempotent(i32 %x, i64 %k) {
; CHECK-LABEL: @low_mask_idempotent(
; CHECK-NOT: pext
; CHECK: %[[AND:.*]] = and i32 %x, %[[MASK:.*]]
; CHECK: %[[CNT:.*]] = call{{.*}} i32 @llvm.ctpop.i32(i32 %[[AND]])
  %km = trunc i64 %k to i32
  %mask = lshr i32 -1, %km
  %c = call i32 @llvm.x86.bmi.pext.32(i32 %x, i32 %mask)
  %p = call i32 @llvm.ctpop.i32(i32 %c)
  ret i32 %p
}
