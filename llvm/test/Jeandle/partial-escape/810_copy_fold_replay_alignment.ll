; RUN: opt -S -verify-each -passes="require<partial-escape-analysis>,partial-escape-transform" -jeandle-vm-callback-log=%S/Inputs/807_copy_fold_packed_groups.cblog %s | FileCheck %s --check-prefixes=CHECK,LE --implicit-check-not="invoke void @jeandle.copy"
; RUN: sed 's/e-p:64:64/E-p:64:64/' %s | opt -S -verify-each -passes="require<partial-escape-analysis>,partial-escape-transform" -jeandle-vm-callback-log=%S/Inputs/807_copy_fold_packed_groups.cblog | FileCheck %s --check-prefixes=CHECK,BE --implicit-check-not="invoke void @jeandle.copy"
; RUN: opt -S -verify-each -passes="require<partial-escape-analysis>,partial-escape-transform,require<partial-escape-analysis>,partial-escape-transform" -jeandle-vm-callback-log=%S/Inputs/807_copy_fold_packed_groups.cblog %s | FileCheck %s --check-prefixes=CHECK,LE --implicit-check-not="invoke void @jeandle.copy"
;
; Whole primitive groups can move to a byte offset that is not naturally
; aligned. Replay must preserve every byte through legal atomic stores while
; retaining the original destination allocation and eliminating the copy.
; Offsets and constants below are independently specified for both byte orders.
target datalayout = "e-p:64:64"
declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32)
declare void @jeandle.copy(ptr addrspace(1), i64, ptr addrspace(1), i64, i64, ptr, ptr, i64, i64)
declare i32 @__gxx_personality_v0(...)

; CHECK-LABEL: define ptr addrspace(1) @shifted_i16(
; CHECK-NOT: @jeandle.new_array
; CHECK: %dst = invoke hotspotcc ptr addrspace(1) @jeandle.new_array
; CHECK: %[[SHIFTED_I16_0:[^ ]+]] = getelementptr inbounds i8, ptr addrspace(1) %dst, i64 17
; LE-NEXT: store atomic i8 34, ptr addrspace(1) %[[SHIFTED_I16_0]] unordered, align 1
; BE-NEXT: store atomic i8 17, ptr addrspace(1) %[[SHIFTED_I16_0]] unordered, align 1
; CHECK: %[[SHIFTED_I16_1:[^ ]+]] = getelementptr inbounds i8, ptr addrspace(1) %dst, i64 18
; LE-NEXT: store atomic i8 17, ptr addrspace(1) %[[SHIFTED_I16_1]] unordered, align 1
; BE-NEXT: store atomic i8 34, ptr addrspace(1) %[[SHIFTED_I16_1]] unordered, align 1
; CHECK-NEXT: call hotspotcc void @jeandle.publish_writes(
; CHECK-NEXT: ret ptr addrspace(1) %dst
define ptr addrspace(1) @shifted_i16() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %src = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 12345 to ptr), i32 32, i32 48, i32 16, i32 1048576) to label %alloc unwind label %u
alloc:
  %dst = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 12345 to ptr), i32 32, i32 48, i32 16, i32 1048576) to label %copy unwind label %u
copy:
  %sp = getelementptr inbounds i8, ptr addrspace(1) %src, i64 16
  store atomic i16 4386, ptr addrspace(1) %sp unordered, align 2
  invoke void @jeandle.copy(ptr addrspace(1) %src, i64 0, ptr addrspace(1) %dst, i64 1, i64 2, ptr null, ptr null, i64 32, i64 32) #0 to label %escape unwind label %u
escape:
  ret ptr addrspace(1) %dst
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define ptr addrspace(1) @shifted_i32(
; CHECK-NOT: @jeandle.new_array
; CHECK: %dst = invoke hotspotcc ptr addrspace(1) @jeandle.new_array
; CHECK: %[[SHIFTED_I32_0:[^ ]+]] = getelementptr inbounds i8, ptr addrspace(1) %dst, i64 18
; LE-NEXT: store atomic i16 772, ptr addrspace(1) %[[SHIFTED_I32_0]] unordered, align 2
; BE-NEXT: store atomic i16 258, ptr addrspace(1) %[[SHIFTED_I32_0]] unordered, align 2
; CHECK: %[[SHIFTED_I32_1:[^ ]+]] = getelementptr inbounds i8, ptr addrspace(1) %dst, i64 20
; LE-NEXT: store atomic i16 258, ptr addrspace(1) %[[SHIFTED_I32_1]] unordered, align 2
; BE-NEXT: store atomic i16 772, ptr addrspace(1) %[[SHIFTED_I32_1]] unordered, align 2
; CHECK-NEXT: call hotspotcc void @jeandle.publish_writes(
; CHECK-NEXT: ret ptr addrspace(1) %dst
define ptr addrspace(1) @shifted_i32() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %src = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 12345 to ptr), i32 32, i32 48, i32 16, i32 1048576) to label %alloc unwind label %u
alloc:
  %dst = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 12345 to ptr), i32 32, i32 48, i32 16, i32 1048576) to label %copy unwind label %u
copy:
  %sp = getelementptr inbounds i8, ptr addrspace(1) %src, i64 16
  store atomic i32 16909060, ptr addrspace(1) %sp unordered, align 4
  invoke void @jeandle.copy(ptr addrspace(1) %src, i64 0, ptr addrspace(1) %dst, i64 2, i64 4, ptr null, ptr null, i64 32, i64 32) #0 to label %escape unwind label %u
escape:
  ret ptr addrspace(1) %dst
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define ptr addrspace(1) @shifted_i64(
; CHECK-NOT: @jeandle.new_array
; CHECK: %dst = invoke hotspotcc ptr addrspace(1) @jeandle.new_array
; CHECK: %[[SHIFTED_I64_0:[^ ]+]] = getelementptr inbounds i8, ptr addrspace(1) %dst, i64 19
; LE-NEXT: store atomic i8 8, ptr addrspace(1) %[[SHIFTED_I64_0]] unordered, align 1
; BE-NEXT: store atomic i8 1, ptr addrspace(1) %[[SHIFTED_I64_0]] unordered, align 1
; CHECK: %[[SHIFTED_I64_1:[^ ]+]] = getelementptr inbounds i8, ptr addrspace(1) %dst, i64 20
; LE-NEXT: store atomic i32 67438087, ptr addrspace(1) %[[SHIFTED_I64_1]] unordered, align 4
; BE-NEXT: store atomic i32 33752069, ptr addrspace(1) %[[SHIFTED_I64_1]] unordered, align 4
; CHECK: %[[SHIFTED_I64_2:[^ ]+]] = getelementptr inbounds i8, ptr addrspace(1) %dst, i64 24
; LE-NEXT: store atomic i16 515, ptr addrspace(1) %[[SHIFTED_I64_2]] unordered, align 2
; BE-NEXT: store atomic i16 1543, ptr addrspace(1) %[[SHIFTED_I64_2]] unordered, align 2
; CHECK: %[[SHIFTED_I64_3:[^ ]+]] = getelementptr inbounds i8, ptr addrspace(1) %dst, i64 26
; LE-NEXT: store atomic i8 1, ptr addrspace(1) %[[SHIFTED_I64_3]] unordered, align 1
; BE-NEXT: store atomic i8 8, ptr addrspace(1) %[[SHIFTED_I64_3]] unordered, align 1
; CHECK-NEXT: call hotspotcc void @jeandle.publish_writes(
; CHECK-NEXT: ret ptr addrspace(1) %dst
define ptr addrspace(1) @shifted_i64() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %src = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 12345 to ptr), i32 32, i32 48, i32 16, i32 1048576) to label %alloc unwind label %u
alloc:
  %dst = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 12345 to ptr), i32 32, i32 48, i32 16, i32 1048576) to label %copy unwind label %u
copy:
  %sp = getelementptr inbounds i8, ptr addrspace(1) %src, i64 16
  store atomic i64 72623859790382856, ptr addrspace(1) %sp unordered, align 8
  invoke void @jeandle.copy(ptr addrspace(1) %src, i64 0, ptr addrspace(1) %dst, i64 3, i64 8, ptr null, ptr null, i64 32, i64 32) #0 to label %escape unwind label %u
escape:
  ret ptr addrspace(1) %dst
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define ptr addrspace(1) @shifted_float(
; CHECK-NOT: @jeandle.new_array
; CHECK: %dst = invoke hotspotcc ptr addrspace(1) @jeandle.new_array
; CHECK: %[[SHIFTED_FLOAT_0:[^ ]+]] = getelementptr inbounds i8, ptr addrspace(1) %dst, i64 17
; LE-NEXT: store atomic i8 0, ptr addrspace(1) %[[SHIFTED_FLOAT_0]] unordered, align 1
; BE-NEXT: store atomic i8 63, ptr addrspace(1) %[[SHIFTED_FLOAT_0]] unordered, align 1
; CHECK: %[[SHIFTED_FLOAT_1:[^ ]+]] = getelementptr inbounds i8, ptr addrspace(1) %dst, i64 18
; CHECK-NEXT: store atomic i16 -16384, ptr addrspace(1) %[[SHIFTED_FLOAT_1]] unordered, align 2
; CHECK: %[[SHIFTED_FLOAT_2:[^ ]+]] = getelementptr inbounds i8, ptr addrspace(1) %dst, i64 20
; LE-NEXT: store atomic i8 63, ptr addrspace(1) %[[SHIFTED_FLOAT_2]] unordered, align 1
; BE-NEXT: store atomic i8 0, ptr addrspace(1) %[[SHIFTED_FLOAT_2]] unordered, align 1
; CHECK-NEXT: call hotspotcc void @jeandle.publish_writes(
; CHECK-NEXT: ret ptr addrspace(1) %dst
define ptr addrspace(1) @shifted_float() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %src = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 12345 to ptr), i32 32, i32 48, i32 16, i32 1048576) to label %alloc unwind label %u
alloc:
  %dst = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 12345 to ptr), i32 32, i32 48, i32 16, i32 1048576) to label %copy unwind label %u
copy:
  %sp = getelementptr inbounds i8, ptr addrspace(1) %src, i64 16
  store atomic float 1.500000e+00, ptr addrspace(1) %sp unordered, align 4
  invoke void @jeandle.copy(ptr addrspace(1) %src, i64 0, ptr addrspace(1) %dst, i64 1, i64 4, ptr null, ptr null, i64 32, i64 32) #0 to label %escape unwind label %u
escape:
  ret ptr addrspace(1) %dst
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define ptr addrspace(1) @aligned_i64(
; CHECK-NOT: @jeandle.new_array
; CHECK: %dst = invoke hotspotcc ptr addrspace(1) @jeandle.new_array
; CHECK: %[[ALIGNED_I64_0:[^ ]+]] = getelementptr inbounds i8, ptr addrspace(1) %dst, i64 24
; CHECK-NEXT: store atomic i64 %value, ptr addrspace(1) %[[ALIGNED_I64_0]] unordered, align 8
; CHECK-NEXT: call hotspotcc void @jeandle.publish_writes(
; CHECK-NEXT: ret ptr addrspace(1) %dst
define ptr addrspace(1) @aligned_i64(i64 %value) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %src = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 12345 to ptr), i32 32, i32 48, i32 16, i32 1048576) to label %alloc unwind label %u
alloc:
  %dst = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 12345 to ptr), i32 32, i32 48, i32 16, i32 1048576) to label %copy unwind label %u
copy:
  %sp = getelementptr inbounds i8, ptr addrspace(1) %src, i64 16
  store atomic i64 %value, ptr addrspace(1) %sp unordered, align 8
  invoke void @jeandle.copy(ptr addrspace(1) %src, i64 0, ptr addrspace(1) %dst, i64 8, i64 8, ptr null, ptr null, i64 32, i64 32) #0 to label %escape unwind label %u
escape:
  ret ptr addrspace(1) %dst
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; A tracked i128 group requires no stronger base alignment than a heap word.
; CHECK-LABEL: define ptr addrspace(1) @wide_group(
; CHECK-NOT: @jeandle.new_array
; CHECK: %dst = invoke hotspotcc ptr addrspace(1) @jeandle.new_array
; CHECK: getelementptr inbounds i8, ptr addrspace(1) %dst, i64 16
; CHECK-NEXT: store atomic i64 {{.*}} unordered, align 8
; CHECK: getelementptr inbounds i8, ptr addrspace(1) %dst, i64 24
; CHECK-NEXT: store atomic i64 {{.*}} unordered, align 8
; CHECK-NEXT: call hotspotcc void @jeandle.publish_writes(
; CHECK-NEXT: ret ptr addrspace(1) %dst
define ptr addrspace(1) @wide_group(i128 %value) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %src = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 12345 to ptr), i32 32, i32 48, i32 16, i32 1048576) to label %alloc unwind label %u
alloc:
  %dst = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 12345 to ptr), i32 32, i32 48, i32 16, i32 1048576) to label %copy unwind label %u
copy:
  %sp = getelementptr inbounds i8, ptr addrspace(1) %src, i64 16
  store i128 %value, ptr addrspace(1) %sp, align 8
  invoke void @jeandle.copy(ptr addrspace(1) %src, i64 0, ptr addrspace(1) %dst, i64 0, i64 16, ptr null, ptr null, i64 32, i64 32) #0 to label %escape unwind label %u
escape:
  ret ptr addrspace(1) %dst
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

attributes #0 = { "jeandle.copy.kind"="arraycopy" "jeandle.copy.validated" }
!java-method-compilation = !{}
