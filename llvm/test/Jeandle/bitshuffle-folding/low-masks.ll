; RUN: opt -S -verify-each -passes='bit-shuffle-folding,instcombine' %s | FileCheck %s
; RUN: opt -S -verify-each -passes='bit-shuffle-folding,instcombine,bit-shuffle-folding,instcombine' %s | FileCheck %s
!java-method-compilation = !{}
declare i32 @llvm.x86.bmi.pext.32(i32, i32)

define i32 @pext_low_lshr_32(i32 %x, i32 %n, ptr %out) {
; CHECK-LABEL: @pext_low_lshr_32(
; CHECK-NOT: call i32 @llvm.x86.bmi
; CHECK: and i32 %{{.*}}, %{{.*}}
; CHECK: ret i32
  %m = lshr i32 -1, %n
  store i32 %m, ptr %out
  %r = call i32 @llvm.x86.bmi.pext.32(i32 %x, i32 %m)
  ret i32 %r
}

define i32 @pext_low_sub_32(i32 %x, i32 %n, ptr %out) {
; CHECK-LABEL: @pext_low_sub_32(
; CHECK-NOT: call i32 @llvm.x86.bmi
; CHECK: and i32 %{{.*}}, %{{.*}}
; CHECK: ret i32
  %b = shl i32 1, %n
  %m = sub i32 %b, 1
  store i32 %m, ptr %out
  %r = call i32 @llvm.x86.bmi.pext.32(i32 %x, i32 %m)
  ret i32 %r
}

define i32 @pext_low_not_32(i32 %x, i32 %n, ptr %out) {
; CHECK-LABEL: @pext_low_not_32(
; CHECK-NOT: call i32 @llvm.x86.bmi
; CHECK: and i32 %{{.*}}, %{{.*}}
; CHECK: ret i32
  %b = shl i32 -1, %n
  %m = xor i32 %b, -1
  store i32 %m, ptr %out
  %r = call i32 @llvm.x86.bmi.pext.32(i32 %x, i32 %m)
  ret i32 %r
}
declare i32 @llvm.x86.bmi.pdep.32(i32, i32)

define i32 @pdep_low_lshr_32(i32 %x, i32 %n, ptr %out) {
; CHECK-LABEL: @pdep_low_lshr_32(
; CHECK-NOT: call i32 @llvm.x86.bmi
; CHECK: and i32 %{{.*}}, %{{.*}}
; CHECK: ret i32
  %m = lshr i32 -1, %n
  store i32 %m, ptr %out
  %r = call i32 @llvm.x86.bmi.pdep.32(i32 %x, i32 %m)
  ret i32 %r
}

define i32 @pdep_low_sub_32(i32 %x, i32 %n, ptr %out) {
; CHECK-LABEL: @pdep_low_sub_32(
; CHECK-NOT: call i32 @llvm.x86.bmi
; CHECK: and i32 %{{.*}}, %{{.*}}
; CHECK: ret i32
  %b = shl i32 1, %n
  %m = sub i32 %b, 1
  store i32 %m, ptr %out
  %r = call i32 @llvm.x86.bmi.pdep.32(i32 %x, i32 %m)
  ret i32 %r
}

define i32 @pdep_low_not_32(i32 %x, i32 %n, ptr %out) {
; CHECK-LABEL: @pdep_low_not_32(
; CHECK-NOT: call i32 @llvm.x86.bmi
; CHECK: and i32 %{{.*}}, %{{.*}}
; CHECK: ret i32
  %b = shl i32 -1, %n
  %m = xor i32 %b, -1
  store i32 %m, ptr %out
  %r = call i32 @llvm.x86.bmi.pdep.32(i32 %x, i32 %m)
  ret i32 %r
}

define i32 @multiuse_stable_32(i32 noundef %x, i32 noundef %m, ptr %out) {
; CHECK-LABEL: @multiuse_stable_32(
; CHECK-NOT: call i32 @llvm.x86.bmi.pdep
; CHECK: and i32 %x, %m
; CHECK: ret i32
  %a = call i32 @llvm.x86.bmi.pext.32(i32 %x, i32 %m)
  store i32 %a, ptr %out
  %b = call i32 @llvm.x86.bmi.pdep.32(i32 %a, i32 %m)
  ret i32 %b
}

define i32 @multiuse_unstable_32(i32 %x, i32 %m, ptr %out) {
; CHECK-LABEL: @multiuse_unstable_32(
; CHECK: call i32 @llvm.x86.bmi.pdep
; CHECK: ret i32
  %a = call i32 @llvm.x86.bmi.pext.32(i32 %x, i32 %m)
  store i32 %a, ptr %out
  %b = call i32 @llvm.x86.bmi.pdep.32(i32 %a, i32 %m)
  ret i32 %b
}
declare i64 @llvm.x86.bmi.pext.64(i64, i64)

define i64 @pext_low_lshr_64(i64 %x, i64 %n, ptr %out) {
; CHECK-LABEL: @pext_low_lshr_64(
; CHECK-NOT: call i64 @llvm.x86.bmi
; CHECK: and i64 %{{.*}}, %{{.*}}
; CHECK: ret i64
  %m = lshr i64 -1, %n
  store i64 %m, ptr %out
  %r = call i64 @llvm.x86.bmi.pext.64(i64 %x, i64 %m)
  ret i64 %r
}

define i64 @pext_low_sub_64(i64 %x, i64 %n, ptr %out) {
; CHECK-LABEL: @pext_low_sub_64(
; CHECK-NOT: call i64 @llvm.x86.bmi
; CHECK: and i64 %{{.*}}, %{{.*}}
; CHECK: ret i64
  %b = shl i64 1, %n
  %m = sub i64 %b, 1
  store i64 %m, ptr %out
  %r = call i64 @llvm.x86.bmi.pext.64(i64 %x, i64 %m)
  ret i64 %r
}

define i64 @pext_low_not_64(i64 %x, i64 %n, ptr %out) {
; CHECK-LABEL: @pext_low_not_64(
; CHECK-NOT: call i64 @llvm.x86.bmi
; CHECK: and i64 %{{.*}}, %{{.*}}
; CHECK: ret i64
  %b = shl i64 -1, %n
  %m = xor i64 %b, -1
  store i64 %m, ptr %out
  %r = call i64 @llvm.x86.bmi.pext.64(i64 %x, i64 %m)
  ret i64 %r
}
declare i64 @llvm.x86.bmi.pdep.64(i64, i64)

define i64 @pdep_low_lshr_64(i64 %x, i64 %n, ptr %out) {
; CHECK-LABEL: @pdep_low_lshr_64(
; CHECK-NOT: call i64 @llvm.x86.bmi
; CHECK: and i64 %{{.*}}, %{{.*}}
; CHECK: ret i64
  %m = lshr i64 -1, %n
  store i64 %m, ptr %out
  %r = call i64 @llvm.x86.bmi.pdep.64(i64 %x, i64 %m)
  ret i64 %r
}

define i64 @pdep_low_sub_64(i64 %x, i64 %n, ptr %out) {
; CHECK-LABEL: @pdep_low_sub_64(
; CHECK-NOT: call i64 @llvm.x86.bmi
; CHECK: and i64 %{{.*}}, %{{.*}}
; CHECK: ret i64
  %b = shl i64 1, %n
  %m = sub i64 %b, 1
  store i64 %m, ptr %out
  %r = call i64 @llvm.x86.bmi.pdep.64(i64 %x, i64 %m)
  ret i64 %r
}

define i64 @pdep_low_not_64(i64 %x, i64 %n, ptr %out) {
; CHECK-LABEL: @pdep_low_not_64(
; CHECK-NOT: call i64 @llvm.x86.bmi
; CHECK: and i64 %{{.*}}, %{{.*}}
; CHECK: ret i64
  %b = shl i64 -1, %n
  %m = xor i64 %b, -1
  store i64 %m, ptr %out
  %r = call i64 @llvm.x86.bmi.pdep.64(i64 %x, i64 %m)
  ret i64 %r
}

define i64 @multiuse_stable_64(i64 noundef %x, i64 noundef %m, ptr %out) {
; CHECK-LABEL: @multiuse_stable_64(
; CHECK-NOT: call i64 @llvm.x86.bmi.pdep
; CHECK: and i64 %x, %m
; CHECK: ret i64
  %a = call i64 @llvm.x86.bmi.pext.64(i64 %x, i64 %m)
  store i64 %a, ptr %out
  %b = call i64 @llvm.x86.bmi.pdep.64(i64 %a, i64 %m)
  ret i64 %b
}

define i64 @multiuse_unstable_64(i64 %x, i64 %m, ptr %out) {
; CHECK-LABEL: @multiuse_unstable_64(
; CHECK: call i64 @llvm.x86.bmi.pdep
; CHECK: ret i64
  %a = call i64 @llvm.x86.bmi.pext.64(i64 %x, i64 %m)
  store i64 %a, ptr %out
  %b = call i64 @llvm.x86.bmi.pdep.64(i64 %a, i64 %m)
  ret i64 %b
}
