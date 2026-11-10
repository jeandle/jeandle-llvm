; RUN: opt < %s -passes='bit-shuffle-folding,instcombine' -mtriple=x86_64-unknown-unknown -verify-each -S | FileCheck %s
; RUN: opt < %s -passes='bit-shuffle-folding,instcombine,bit-shuffle-folding,instcombine' -mtriple=x86_64-unknown-unknown -verify-each -S | FileCheck %s

declare i32 @llvm.x86.bmi.pext.32(i32, i32)
declare i32 @llvm.x86.bmi.pdep.32(i32, i32)

define i32 @pdep_pext_32(i32 %x, i32 %m) {
; CHECK-LABEL: @pdep_pext_32(
; CHECK: %[[R:.*]] = and i32 %x, %m
; CHECK: ret i32 %[[R]]
entry:
  %inner = call i32 @llvm.x86.bmi.pext.32(i32 %x, i32 %m)
  %outer = call i32 @llvm.x86.bmi.pdep.32(i32 %inner, i32 %m)
  ret i32 %outer
}

define i32 @pext_pdep_32(i32 %x, i32 %m) {
; CHECK-LABEL: @pext_pdep_32(
; CHECK: %[[F:.*]] = freeze i32 %m
; CHECK: %[[M:.*]] = call i32 @llvm.x86.bmi.pext.32(i32 %[[F]], i32 %[[F]])
; CHECK: %[[R:.*]] = and i32 %x, %[[M]]
; CHECK: ret i32 %[[R]]
entry:
  %inner = call i32 @llvm.x86.bmi.pdep.32(i32 %x, i32 %m)
  %outer = call i32 @llvm.x86.bmi.pext.32(i32 %inner, i32 %m)
  ret i32 %outer
}

define i32 @pext_pdep_noundef_32(i32 %x, i32 noundef %m) {
; CHECK-LABEL: @pext_pdep_noundef_32(
; CHECK: %[[M:.*]] = call i32 @llvm.x86.bmi.pext.32(i32 %m, i32 %m)
; CHECK: %[[R:.*]] = and i32 %x, %[[M]]
; CHECK: ret i32 %[[R]]
entry:
  %inner = call i32 @llvm.x86.bmi.pdep.32(i32 %x, i32 %m)
  %outer = call i32 @llvm.x86.bmi.pext.32(i32 %inner, i32 %m)
  ret i32 %outer
}

define i32 @pext_pdep_frozen_32(i32 %x, i32 %m) {
; CHECK-LABEL: @pext_pdep_frozen_32(
; CHECK: %f = freeze i32 %m
; CHECK: %[[M:.*]] = call i32 @llvm.x86.bmi.pext.32(i32 %f, i32 %f)
; CHECK: %[[R:.*]] = and i32 %x, %[[M]]
; CHECK: ret i32 %[[R]]
entry:
  %f = freeze i32 %m
  %inner = call i32 @llvm.x86.bmi.pdep.32(i32 %x, i32 %f)
  %outer = call i32 @llvm.x86.bmi.pext.32(i32 %inner, i32 %f)
  ret i32 %outer
}

define i32 @pdep_allones_32(i32 %m) {
; CHECK-LABEL: @pdep_allones_32(
; CHECK: ret i32 %m
entry:
  %r = call i32 @llvm.x86.bmi.pdep.32(i32 -1, i32 %m)
  ret i32 %r
}

define i32 @pext_single_32(i32 %x, i32 %s) {
; CHECK-LABEL: @pext_single_32(
; CHECK: %[[S:.*]] = lshr i32 %x, %s
; CHECK: %[[R:.*]] = and i32 %[[S]], 1
; CHECK: ret i32 %[[R]]
entry:
  %m = shl i32 1, %s
  %r = call i32 @llvm.x86.bmi.pext.32(i32 %x, i32 %m)
  ret i32 %r
}

define i32 @pdep_single_32(i32 %x, i32 %s) {
; CHECK-LABEL: @pdep_single_32(
; CHECK: %[[B:.*]] = and i32 %x, 1
; CHECK: %[[R:.*]] = shl{{( nuw)?}} i32 %[[B]], %s
; CHECK: ret i32 %[[R]]
entry:
  %m = shl i32 1, %s
  %r = call i32 @llvm.x86.bmi.pdep.32(i32 %x, i32 %m)
  ret i32 %r
}

define i32 @pext_high_32(i32 %x, i32 %s) {
; CHECK-LABEL: @pext_high_32(
; CHECK: %[[R:.*]] = lshr i32 %x, %s
; CHECK: ret i32 %[[R]]
entry:
  %m = shl i32 -1, %s
  %r = call i32 @llvm.x86.bmi.pext.32(i32 %x, i32 %m)
  ret i32 %r
}

define i32 @pdep_high_32(i32 %x, i32 %s) {
; CHECK-LABEL: @pdep_high_32(
; CHECK: %[[R:.*]] = shl i32 %x, %s
; CHECK: ret i32 %[[R]]
entry:
  %m = shl i32 -1, %s
  %r = call i32 @llvm.x86.bmi.pdep.32(i32 %x, i32 %m)
  ret i32 %r
}

define i32 @pdep_mismatch_32(i32 %x, i32 %m, i32 %n) {
; CHECK-LABEL: @pdep_mismatch_32(
; CHECK: %inner = call i32 @llvm.x86.bmi.pext.32(i32 %x, i32 %m)
; CHECK: %outer = call i32 @llvm.x86.bmi.pdep.32(i32 %inner, i32 %n)
; CHECK: ret i32 %outer
entry:
  %inner = call i32 @llvm.x86.bmi.pext.32(i32 %x, i32 %m)
  %outer = call i32 @llvm.x86.bmi.pdep.32(i32 %inner, i32 %n)
  ret i32 %outer
}

define i32 @pdep_multiuse_32(i32 %x, i32 %m) {
; CHECK-LABEL: @pdep_multiuse_32(
; CHECK: %inner = call i32 @llvm.x86.bmi.pext.32(i32 %x, i32 %m)
; CHECK: %outer = call i32 @llvm.x86.bmi.pdep.32(i32 %inner, i32 %m)
; CHECK: %r = xor i32 %inner, %outer
; CHECK: ret i32 %r
entry:
  %inner = call i32 @llvm.x86.bmi.pext.32(i32 %x, i32 %m)
  %outer = call i32 @llvm.x86.bmi.pdep.32(i32 %inner, i32 %m)
  %r = xor i32 %inner, %outer
  ret i32 %r
}

define i32 @pext_mismatch_32(i32 %x, i32 %m, i32 %n) {
; CHECK-LABEL: @pext_mismatch_32(
; CHECK: %inner = call i32 @llvm.x86.bmi.pdep.32(i32 %x, i32 %m)
; CHECK: %outer = call i32 @llvm.x86.bmi.pext.32(i32 %inner, i32 %n)
; CHECK: ret i32 %outer
entry:
  %inner = call i32 @llvm.x86.bmi.pdep.32(i32 %x, i32 %m)
  %outer = call i32 @llvm.x86.bmi.pext.32(i32 %inner, i32 %n)
  ret i32 %outer
}

define i32 @pext_multiuse_32(i32 %x, i32 %m) {
; CHECK-LABEL: @pext_multiuse_32(
; CHECK: %inner = call i32 @llvm.x86.bmi.pdep.32(i32 %x, i32 %m)
; CHECK: %outer = call i32 @llvm.x86.bmi.pext.32(i32 %inner, i32 %m)
; CHECK: %r = xor i32 %inner, %outer
; CHECK: ret i32 %r
entry:
  %inner = call i32 @llvm.x86.bmi.pdep.32(i32 %x, i32 %m)
  %outer = call i32 @llvm.x86.bmi.pext.32(i32 %inner, i32 %m)
  %r = xor i32 %inner, %outer
  ret i32 %r
}

define i32 @pext_shift_multiuse_32(i32 %x, i32 %s) {
; CHECK-LABEL: @pext_shift_multiuse_32(
; CHECK: %m = shl{{( nuw)?}} i32 1, %s
; CHECK: %r = call i32 @llvm.x86.bmi.pext.32(i32 %x, i32 %m)
; CHECK: %v = xor i32 %r, %m
; CHECK: ret i32 %v
entry:
  %m = shl i32 1, %s
  %r = call i32 @llvm.x86.bmi.pext.32(i32 %x, i32 %m)
  %v = xor i32 %r, %m
  ret i32 %v
}

define i32 @pdep_shift_multiuse_32(i32 %x, i32 %s) {
; CHECK-LABEL: @pdep_shift_multiuse_32(
; CHECK: %m = shl{{( nuw)?}} i32 1, %s
; CHECK: %r = call i32 @llvm.x86.bmi.pdep.32(i32 %x, i32 %m)
; CHECK: %v = xor i32 %r, %m
; CHECK: ret i32 %v
entry:
  %m = shl i32 1, %s
  %r = call i32 @llvm.x86.bmi.pdep.32(i32 %x, i32 %m)
  %v = xor i32 %r, %m
  ret i32 %v
}

define i32 @pdep_other_source_32(i32 %m) {
; CHECK-LABEL: @pdep_other_source_32(
; CHECK: %r = call i32 @llvm.x86.bmi.pdep.32(i32 -2, i32 %m)
; CHECK: ret i32 %r
entry:
  %r = call i32 @llvm.x86.bmi.pdep.32(i32 -2, i32 %m)
  ret i32 %r
}

declare i64 @llvm.x86.bmi.pext.64(i64, i64)
declare i64 @llvm.x86.bmi.pdep.64(i64, i64)

define i64 @pdep_pext_64(i64 %x, i64 %m) {
; CHECK-LABEL: @pdep_pext_64(
; CHECK: %[[R:.*]] = and i64 %x, %m
; CHECK: ret i64 %[[R]]
entry:
  %inner = call i64 @llvm.x86.bmi.pext.64(i64 %x, i64 %m)
  %outer = call i64 @llvm.x86.bmi.pdep.64(i64 %inner, i64 %m)
  ret i64 %outer
}

define i64 @pext_pdep_64(i64 %x, i64 %m) {
; CHECK-LABEL: @pext_pdep_64(
; CHECK: %[[F:.*]] = freeze i64 %m
; CHECK: %[[M:.*]] = call i64 @llvm.x86.bmi.pext.64(i64 %[[F]], i64 %[[F]])
; CHECK: %[[R:.*]] = and i64 %x, %[[M]]
; CHECK: ret i64 %[[R]]
entry:
  %inner = call i64 @llvm.x86.bmi.pdep.64(i64 %x, i64 %m)
  %outer = call i64 @llvm.x86.bmi.pext.64(i64 %inner, i64 %m)
  ret i64 %outer
}

define i64 @pext_pdep_noundef_64(i64 %x, i64 noundef %m) {
; CHECK-LABEL: @pext_pdep_noundef_64(
; CHECK: %[[M:.*]] = call i64 @llvm.x86.bmi.pext.64(i64 %m, i64 %m)
; CHECK: %[[R:.*]] = and i64 %x, %[[M]]
; CHECK: ret i64 %[[R]]
entry:
  %inner = call i64 @llvm.x86.bmi.pdep.64(i64 %x, i64 %m)
  %outer = call i64 @llvm.x86.bmi.pext.64(i64 %inner, i64 %m)
  ret i64 %outer
}

define i64 @pext_pdep_frozen_64(i64 %x, i64 %m) {
; CHECK-LABEL: @pext_pdep_frozen_64(
; CHECK: %f = freeze i64 %m
; CHECK: %[[M:.*]] = call i64 @llvm.x86.bmi.pext.64(i64 %f, i64 %f)
; CHECK: %[[R:.*]] = and i64 %x, %[[M]]
; CHECK: ret i64 %[[R]]
entry:
  %f = freeze i64 %m
  %inner = call i64 @llvm.x86.bmi.pdep.64(i64 %x, i64 %f)
  %outer = call i64 @llvm.x86.bmi.pext.64(i64 %inner, i64 %f)
  ret i64 %outer
}

define i64 @pdep_allones_64(i64 %m) {
; CHECK-LABEL: @pdep_allones_64(
; CHECK: ret i64 %m
entry:
  %r = call i64 @llvm.x86.bmi.pdep.64(i64 -1, i64 %m)
  ret i64 %r
}

define i64 @pext_single_64(i64 %x, i64 %s) {
; CHECK-LABEL: @pext_single_64(
; CHECK: %[[S:.*]] = lshr i64 %x, %s
; CHECK: %[[R:.*]] = and i64 %[[S]], 1
; CHECK: ret i64 %[[R]]
entry:
  %m = shl i64 1, %s
  %r = call i64 @llvm.x86.bmi.pext.64(i64 %x, i64 %m)
  ret i64 %r
}

define i64 @pdep_single_64(i64 %x, i64 %s) {
; CHECK-LABEL: @pdep_single_64(
; CHECK: %[[B:.*]] = and i64 %x, 1
; CHECK: %[[R:.*]] = shl{{( nuw)?}} i64 %[[B]], %s
; CHECK: ret i64 %[[R]]
entry:
  %m = shl i64 1, %s
  %r = call i64 @llvm.x86.bmi.pdep.64(i64 %x, i64 %m)
  ret i64 %r
}

define i64 @pext_high_64(i64 %x, i64 %s) {
; CHECK-LABEL: @pext_high_64(
; CHECK: %[[R:.*]] = lshr i64 %x, %s
; CHECK: ret i64 %[[R]]
entry:
  %m = shl i64 -1, %s
  %r = call i64 @llvm.x86.bmi.pext.64(i64 %x, i64 %m)
  ret i64 %r
}

define i64 @pdep_high_64(i64 %x, i64 %s) {
; CHECK-LABEL: @pdep_high_64(
; CHECK: %[[R:.*]] = shl i64 %x, %s
; CHECK: ret i64 %[[R]]
entry:
  %m = shl i64 -1, %s
  %r = call i64 @llvm.x86.bmi.pdep.64(i64 %x, i64 %m)
  ret i64 %r
}

define i64 @pdep_mismatch_64(i64 %x, i64 %m, i64 %n) {
; CHECK-LABEL: @pdep_mismatch_64(
; CHECK: %inner = call i64 @llvm.x86.bmi.pext.64(i64 %x, i64 %m)
; CHECK: %outer = call i64 @llvm.x86.bmi.pdep.64(i64 %inner, i64 %n)
; CHECK: ret i64 %outer
entry:
  %inner = call i64 @llvm.x86.bmi.pext.64(i64 %x, i64 %m)
  %outer = call i64 @llvm.x86.bmi.pdep.64(i64 %inner, i64 %n)
  ret i64 %outer
}

define i64 @pdep_multiuse_64(i64 %x, i64 %m) {
; CHECK-LABEL: @pdep_multiuse_64(
; CHECK: %inner = call i64 @llvm.x86.bmi.pext.64(i64 %x, i64 %m)
; CHECK: %outer = call i64 @llvm.x86.bmi.pdep.64(i64 %inner, i64 %m)
; CHECK: %r = xor i64 %inner, %outer
; CHECK: ret i64 %r
entry:
  %inner = call i64 @llvm.x86.bmi.pext.64(i64 %x, i64 %m)
  %outer = call i64 @llvm.x86.bmi.pdep.64(i64 %inner, i64 %m)
  %r = xor i64 %inner, %outer
  ret i64 %r
}

define i64 @pext_mismatch_64(i64 %x, i64 %m, i64 %n) {
; CHECK-LABEL: @pext_mismatch_64(
; CHECK: %inner = call i64 @llvm.x86.bmi.pdep.64(i64 %x, i64 %m)
; CHECK: %outer = call i64 @llvm.x86.bmi.pext.64(i64 %inner, i64 %n)
; CHECK: ret i64 %outer
entry:
  %inner = call i64 @llvm.x86.bmi.pdep.64(i64 %x, i64 %m)
  %outer = call i64 @llvm.x86.bmi.pext.64(i64 %inner, i64 %n)
  ret i64 %outer
}

define i64 @pext_multiuse_64(i64 %x, i64 %m) {
; CHECK-LABEL: @pext_multiuse_64(
; CHECK: %inner = call i64 @llvm.x86.bmi.pdep.64(i64 %x, i64 %m)
; CHECK: %outer = call i64 @llvm.x86.bmi.pext.64(i64 %inner, i64 %m)
; CHECK: %r = xor i64 %inner, %outer
; CHECK: ret i64 %r
entry:
  %inner = call i64 @llvm.x86.bmi.pdep.64(i64 %x, i64 %m)
  %outer = call i64 @llvm.x86.bmi.pext.64(i64 %inner, i64 %m)
  %r = xor i64 %inner, %outer
  ret i64 %r
}

define i64 @pext_shift_multiuse_64(i64 %x, i64 %s) {
; CHECK-LABEL: @pext_shift_multiuse_64(
; CHECK: %m = shl{{( nuw)?}} i64 1, %s
; CHECK: %r = call i64 @llvm.x86.bmi.pext.64(i64 %x, i64 %m)
; CHECK: %v = xor i64 %r, %m
; CHECK: ret i64 %v
entry:
  %m = shl i64 1, %s
  %r = call i64 @llvm.x86.bmi.pext.64(i64 %x, i64 %m)
  %v = xor i64 %r, %m
  ret i64 %v
}

define i64 @pdep_shift_multiuse_64(i64 %x, i64 %s) {
; CHECK-LABEL: @pdep_shift_multiuse_64(
; CHECK: %m = shl{{( nuw)?}} i64 1, %s
; CHECK: %r = call i64 @llvm.x86.bmi.pdep.64(i64 %x, i64 %m)
; CHECK: %v = xor i64 %r, %m
; CHECK: ret i64 %v
entry:
  %m = shl i64 1, %s
  %r = call i64 @llvm.x86.bmi.pdep.64(i64 %x, i64 %m)
  %v = xor i64 %r, %m
  ret i64 %v
}

define i64 @pdep_other_source_64(i64 %m) {
; CHECK-LABEL: @pdep_other_source_64(
; CHECK: %r = call i64 @llvm.x86.bmi.pdep.64(i64 -2, i64 %m)
; CHECK: ret i64 %r
entry:
  %r = call i64 @llvm.x86.bmi.pdep.64(i64 -2, i64 %m)
  ret i64 %r
}

define i32 @pext_high_java_shift_32(i32 %x, i32 %s) {
; CHECK-LABEL: @pext_high_java_shift_32(
; CHECK: %n = and i32 %s, 31
; CHECK: %[[R:.*]] = lshr i32 %x, %n
; CHECK: ret i32 %[[R]]
entry:
  %n = and i32 %s, 31
  %m = shl i32 -1, %n
  %r = call i32 @llvm.x86.bmi.pext.32(i32 %x, i32 %m)
  ret i32 %r
}

define i32 @pdep_high_java_shift_32(i32 %x, i32 %s) {
; CHECK-LABEL: @pdep_high_java_shift_32(
; CHECK: %n = and i32 %s, 31
; CHECK: %[[R:.*]] = shl i32 %x, %n
; CHECK: ret i32 %[[R]]
entry:
  %n = and i32 %s, 31
  %m = shl i32 -1, %n
  %r = call i32 @llvm.x86.bmi.pdep.32(i32 %x, i32 %m)
  ret i32 %r
}

define i64 @pext_high_java_shift_64(i64 %x, i64 %s) {
; CHECK-LABEL: @pext_high_java_shift_64(
; CHECK: %n = and i64 %s, 63
; CHECK: %[[R:.*]] = lshr i64 %x, %n
; CHECK: ret i64 %[[R]]
entry:
  %n = and i64 %s, 63
  %m = shl i64 -1, %n
  %r = call i64 @llvm.x86.bmi.pext.64(i64 %x, i64 %m)
  ret i64 %r
}

define i64 @pdep_high_java_shift_64(i64 %x, i64 %s) {
; CHECK-LABEL: @pdep_high_java_shift_64(
; CHECK: %n = and i64 %s, 63
; CHECK: %[[R:.*]] = shl i64 %x, %n
; CHECK: ret i64 %[[R]]
entry:
  %n = and i64 %s, 63
  %m = shl i64 -1, %n
  %r = call i64 @llvm.x86.bmi.pdep.64(i64 %x, i64 %m)
  ret i64 %r
}

define i32 @pext_composition_undef_source_32(i32 %m) {
; CHECK-LABEL: @pext_composition_undef_source_32(
; CHECK: ret i32 0
entry:
  %inner = call i32 @llvm.x86.bmi.pdep.32(i32 undef, i32 %m)
  %outer = call i32 @llvm.x86.bmi.pext.32(i32 %inner, i32 %m)
  ret i32 %outer
}

define i32 @pext_composition_poison_source_32(i32 %m) {
; CHECK-LABEL: @pext_composition_poison_source_32(
; CHECK: ret i32 poison
entry:
  %inner = call i32 @llvm.x86.bmi.pdep.32(i32 poison, i32 %m)
  %outer = call i32 @llvm.x86.bmi.pext.32(i32 %inner, i32 %m)
  ret i32 %outer
}

define i32 @pdep_composition_undef_source_32(i32 %m) {
; CHECK-LABEL: @pdep_composition_undef_source_32(
; CHECK: ret i32 0
entry:
  %inner = call i32 @llvm.x86.bmi.pext.32(i32 undef, i32 %m)
  %outer = call i32 @llvm.x86.bmi.pdep.32(i32 %inner, i32 %m)
  ret i32 %outer
}

define i32 @pdep_composition_poison_source_32(i32 %m) {
; CHECK-LABEL: @pdep_composition_poison_source_32(
; CHECK: ret i32 poison
entry:
  %inner = call i32 @llvm.x86.bmi.pext.32(i32 poison, i32 %m)
  %outer = call i32 @llvm.x86.bmi.pdep.32(i32 %inner, i32 %m)
  ret i32 %outer
}

define i32 @pext_pdep_undef_mask_32(i32 %x) {
; CHECK-LABEL: @pext_pdep_undef_mask_32(
; CHECK: ret i32 0
entry:
  %inner = call i32 @llvm.x86.bmi.pdep.32(i32 %x, i32 undef)
  %outer = call i32 @llvm.x86.bmi.pext.32(i32 %inner, i32 undef)
  ret i32 %outer
}

define i32 @pext_pdep_poison_mask_32(i32 %x) {
; CHECK-LABEL: @pext_pdep_poison_mask_32(
; CHECK: %[[M:.*]] = call i32 @llvm.x86.bmi.pext.32(i32 poison, i32 poison)
; CHECK: %[[R:.*]] = and i32 %x, %[[M]]
; CHECK: ret i32 %[[R]]
entry:
  %inner = call i32 @llvm.x86.bmi.pdep.32(i32 %x, i32 poison)
  %outer = call i32 @llvm.x86.bmi.pext.32(i32 %inner, i32 poison)
  ret i32 %outer
}

define i64 @pext_composition_undef_source_64(i64 %m) {
; CHECK-LABEL: @pext_composition_undef_source_64(
; CHECK: ret i64 0
entry:
  %inner = call i64 @llvm.x86.bmi.pdep.64(i64 undef, i64 %m)
  %outer = call i64 @llvm.x86.bmi.pext.64(i64 %inner, i64 %m)
  ret i64 %outer
}

define i64 @pext_composition_poison_source_64(i64 %m) {
; CHECK-LABEL: @pext_composition_poison_source_64(
; CHECK: ret i64 poison
entry:
  %inner = call i64 @llvm.x86.bmi.pdep.64(i64 poison, i64 %m)
  %outer = call i64 @llvm.x86.bmi.pext.64(i64 %inner, i64 %m)
  ret i64 %outer
}

define i64 @pdep_composition_undef_source_64(i64 %m) {
; CHECK-LABEL: @pdep_composition_undef_source_64(
; CHECK: ret i64 0
entry:
  %inner = call i64 @llvm.x86.bmi.pext.64(i64 undef, i64 %m)
  %outer = call i64 @llvm.x86.bmi.pdep.64(i64 %inner, i64 %m)
  ret i64 %outer
}

define i64 @pdep_composition_poison_source_64(i64 %m) {
; CHECK-LABEL: @pdep_composition_poison_source_64(
; CHECK: ret i64 poison
entry:
  %inner = call i64 @llvm.x86.bmi.pext.64(i64 poison, i64 %m)
  %outer = call i64 @llvm.x86.bmi.pdep.64(i64 %inner, i64 %m)
  ret i64 %outer
}

define i64 @pext_pdep_undef_mask_64(i64 %x) {
; CHECK-LABEL: @pext_pdep_undef_mask_64(
; CHECK: ret i64 0
entry:
  %inner = call i64 @llvm.x86.bmi.pdep.64(i64 %x, i64 undef)
  %outer = call i64 @llvm.x86.bmi.pext.64(i64 %inner, i64 undef)
  ret i64 %outer
}

define i64 @pext_pdep_poison_mask_64(i64 %x) {
; CHECK-LABEL: @pext_pdep_poison_mask_64(
; CHECK: %[[M:.*]] = call i64 @llvm.x86.bmi.pext.64(i64 poison, i64 poison)
; CHECK: %[[R:.*]] = and i64 %x, %[[M]]
; CHECK: ret i64 %[[R]]
entry:
  %inner = call i64 @llvm.x86.bmi.pdep.64(i64 %x, i64 poison)
  %outer = call i64 @llvm.x86.bmi.pext.64(i64 %inner, i64 poison)
  ret i64 %outer
}


!java-method-compilation = !{!0}
!0 = !{}

define i32 @musttail_32(i32 %x, i32 %m) {
; CHECK-LABEL: @musttail_32(
; CHECK: %r = musttail call i32 @llvm.x86.bmi.pdep.32(i32 -1, i32 %m)
; CHECK: ret i32 %r
  %r = musttail call i32 @llvm.x86.bmi.pdep.32(i32 -1, i32 %m)
  ret i32 %r
}

define i32 @bundled_32(i32 %m) {
; CHECK-LABEL: @bundled_32(
; CHECK: %r = call i32 @llvm.x86.bmi.pdep.32(i32 -1, i32 %m) [ "deopt"(i32 %m) ]
; CHECK: ret i32 %r
  %r = call i32 @llvm.x86.bmi.pdep.32(i32 -1, i32 %m) [ "deopt"(i32 %m) ]
  ret i32 %r
}

define i32 @bundled_inner_32(i32 %x, i32 %m) {
; CHECK-LABEL: @bundled_inner_32(
; CHECK: %inner = call i32 @llvm.x86.bmi.pext.32(i32 %x, i32 %m) [ "deopt"(i32 %m) ]
; CHECK: %outer = call i32 @llvm.x86.bmi.pdep.32(i32 %inner, i32 %m)
; CHECK: ret i32 %outer
  %inner = call i32 @llvm.x86.bmi.pext.32(i32 %x, i32 %m) [ "deopt"(i32 %m) ]
  %outer = call i32 @llvm.x86.bmi.pdep.32(i32 %inner, i32 %m)
  ret i32 %outer
}

define i64 @musttail_64(i64 %x, i64 %m) {
; CHECK-LABEL: @musttail_64(
; CHECK: %r = musttail call i64 @llvm.x86.bmi.pdep.64(i64 -1, i64 %m)
; CHECK: ret i64 %r
  %r = musttail call i64 @llvm.x86.bmi.pdep.64(i64 -1, i64 %m)
  ret i64 %r
}

define i64 @bundled_64(i64 %m) {
; CHECK-LABEL: @bundled_64(
; CHECK: %r = call i64 @llvm.x86.bmi.pdep.64(i64 -1, i64 %m) [ "deopt"(i64 %m) ]
; CHECK: ret i64 %r
  %r = call i64 @llvm.x86.bmi.pdep.64(i64 -1, i64 %m) [ "deopt"(i64 %m) ]
  ret i64 %r
}

define i64 @bundled_inner_64(i64 %x, i64 %m) {
; CHECK-LABEL: @bundled_inner_64(
; CHECK: %inner = call i64 @llvm.x86.bmi.pext.64(i64 %x, i64 %m) [ "deopt"(i64 %m) ]
; CHECK: %outer = call i64 @llvm.x86.bmi.pdep.64(i64 %inner, i64 %m)
; CHECK: ret i64 %outer
  %inner = call i64 @llvm.x86.bmi.pext.64(i64 %x, i64 %m) [ "deopt"(i64 %m) ]
  %outer = call i64 @llvm.x86.bmi.pdep.64(i64 %inner, i64 %m)
  ret i64 %outer
}

define i32 @nested_compositions_32(i32 %x, i32 %m) {
; CHECK-LABEL: @nested_compositions_32(
; CHECK: %[[R:.*]] = and i32 %x, %m
; CHECK: ret i32 %[[R]]
  %a = call i32 @llvm.x86.bmi.pext.32(i32 %x, i32 %m)
  %b = call i32 @llvm.x86.bmi.pdep.32(i32 %a, i32 %m)
  %c = call i32 @llvm.x86.bmi.pext.32(i32 %b, i32 %m)
  %d = call i32 @llvm.x86.bmi.pdep.32(i32 %c, i32 %m)
  ret i32 %d
}

define i64 @nested_compositions_64(i64 %x, i64 %m) {
; CHECK-LABEL: @nested_compositions_64(
; CHECK: %[[R:.*]] = and i64 %x, %m
; CHECK: ret i64 %[[R]]
  %a = call i64 @llvm.x86.bmi.pext.64(i64 %x, i64 %m)
  %b = call i64 @llvm.x86.bmi.pdep.64(i64 %a, i64 %m)
  %c = call i64 @llvm.x86.bmi.pext.64(i64 %b, i64 %m)
  %d = call i64 @llvm.x86.bmi.pdep.64(i64 %c, i64 %m)
  ret i64 %d
}
