; RUN: opt -S -passes=character-intrinsic-specialization -verify-each %s | FileCheck %s
; RUN: opt -S -passes=character-intrinsic-specialization -jeandle-pre-pea-full-unroll-max-count=16 -verify-each %s | FileCheck %s --check-prefix=CAP
; RUN: opt -S -passes=character-intrinsic-specialization -jeandle-pea=false -verify-each %s | FileCheck %s --check-prefix=CAP
;
; Larger operations need a bounded local array. Exposure creates one counted
; iteration for a conservative estimate with the existing unroller cost API.
; Approved calls expand directly within the shared loop and function budgets.

target datalayout = "e-p:64:64-p1:64:64"
@arrayOopDesc.base_offset_in_bytes.byte = constant i32 16
@arrayOopDesc.base_offset_in_bytes.char = constant i32 16
declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32, i1, i1)
declare hotspotcc i32 @jeandle.encode_array(ptr addrspace(1), i32, ptr addrspace(1), i32, i32, i1, i1)
declare hotspotcc i32 @jeandle.count_positives(ptr addrspace(1), i32, i32)

; CHECK-LABEL: @external8(
; CHECK: load atomic i16
; CHECK: ret i32
define i32 @external8(ptr addrspace(1) %src, ptr addrspace(1) %dst) {
  %r = call hotspotcc i32 @jeandle.encode_array(ptr addrspace(1) %src, i32 0, ptr addrspace(1) %dst, i32 0, i32 8, i1 false, i1 true)
  ret i32 %r
}

; CHECK-LABEL: @external9(
; CHECK: call hotspotcc i32 @jeandle.encode_array
; CHECK: ret i32
define i32 @external9(ptr addrspace(1) %src, ptr addrspace(1) %dst) {
  %r = call hotspotcc i32 @jeandle.encode_array(ptr addrspace(1) %src, i32 0, ptr addrspace(1) %dst, i32 0, i32 9, i1 false, i1 true)
  ret i32 %r
}

; CHECK-LABEL: @external16(
; CHECK: call hotspotcc i32 @jeandle.encode_array
; CHECK: ret i32
define i32 @external16(ptr addrspace(1) %src, ptr addrspace(1) %dst) {
  %r = call hotspotcc i32 @jeandle.encode_array(ptr addrspace(1) %src, i32 0, ptr addrspace(1) %dst, i32 0, i32 16, i1 false, i1 true)
  ret i32 %r
}

; CHECK-LABEL: @external17(
; CHECK: call hotspotcc i32 @jeandle.encode_array
; CHECK: ret i32
define i32 @external17(ptr addrspace(1) %src, ptr addrspace(1) %dst) {
  %r = call hotspotcc i32 @jeandle.encode_array(ptr addrspace(1) %src, i32 0, ptr addrspace(1) %dst, i32 0, i32 17, i1 false, i1 true)
  ret i32 %r
}

; CHECK-LABEL: @external128(
; CHECK: call hotspotcc i32 @jeandle.encode_array
; CHECK: ret i32
define i32 @external128(ptr addrspace(1) %src, ptr addrspace(1) %dst) {
  %r = call hotspotcc i32 @jeandle.encode_array(ptr addrspace(1) %src, i32 0, ptr addrspace(1) %dst, i32 0, i32 128, i1 false, i1 true)
  ret i32 %r
}

; CHECK-LABEL: @external129(
; CHECK: call hotspotcc i32 @jeandle.encode_array
; CHECK: ret i32
define i32 @external129(ptr addrspace(1) %src, ptr addrspace(1) %dst) {
  %r = call hotspotcc i32 @jeandle.encode_array(ptr addrspace(1) %src, i32 0, ptr addrspace(1) %dst, i32 0, i32 129, i1 false, i1 true)
  ret i32 %r
}

; CHECK-LABEL: @local17(
; CHECK: load atomic i16
; CHECK: store atomic i8
; CHECK-NOT: @jeandle.encode_array
; CHECK: ret i32
; CAP-LABEL: @local17(
; CAP: call hotspotcc i32 @jeandle.encode_array
define i32 @local17(ptr addrspace(1) %external) {
  %local = call hotspotcc ptr addrspace(1) @jeandle.new_array(ptr null, i32 17, i32 50, i32 16, i32 100, i1 false, i1 false)
  %r = call hotspotcc i32 @jeandle.encode_array(ptr addrspace(1) %local, i32 0, ptr addrspace(1) %external, i32 0, i32 17, i1 false, i1 true)
  ret i32 %r
}

; CHECK-LABEL: @local128(
; CHECK: call hotspotcc i32 @jeandle.encode_array
; CHECK: ret i32
; CAP-LABEL: @local128(
; CAP: call hotspotcc i32 @jeandle.encode_array
define i32 @local128(ptr addrspace(1) %external) {
  %local = call hotspotcc ptr addrspace(1) @jeandle.new_array(ptr null, i32 128, i32 272, i32 16, i32 100, i1 false, i1 false)
  %r = call hotspotcc i32 @jeandle.encode_array(ptr addrspace(1) %local, i32 0, ptr addrspace(1) %external, i32 0, i32 128, i1 false, i1 true)
  ret i32 %r
}

; CHECK-LABEL: @local129(
; CHECK: call hotspotcc i32 @jeandle.encode_array
; CHECK: ret i32
define i32 @local129(ptr addrspace(1) %external) {
  %local = call hotspotcc ptr addrspace(1) @jeandle.new_array(ptr null, i32 129, i32 274, i32 16, i32 100, i1 false, i1 false)
  %r = call hotspotcc i32 @jeandle.encode_array(ptr addrspace(1) %local, i32 0, ptr addrspace(1) %external, i32 0, i32 129, i1 false, i1 true)
  ret i32 %r
}

; CHECK-LABEL: @utf16local64(
; CHECK: call hotspotcc i32 @jeandle.encode_array
; CHECK: ret i32
; CAP-LABEL: @utf16local64(
; CAP: call hotspotcc i32 @jeandle.encode_array
define i32 @utf16local64(ptr addrspace(1) %external) {
  %local = call hotspotcc ptr addrspace(1) @jeandle.new_array(ptr null, i32 128, i32 272, i32 16, i32 100, i1 false, i1 false)
  %r = call hotspotcc i32 @jeandle.encode_array(ptr addrspace(1) %local, i32 0, ptr addrspace(1) %external, i32 0, i32 64, i1 true, i1 true)
  ret i32 %r
}

; CHECK-LABEL: @utf16local65(
; CHECK: call hotspotcc i32 @jeandle.encode_array
; CHECK: ret i32
define i32 @utf16local65(ptr addrspace(1) %external) {
  %local = call hotspotcc ptr addrspace(1) @jeandle.new_array(ptr null, i32 130, i32 276, i32 16, i32 100, i1 false, i1 false)
  %r = call hotspotcc i32 @jeandle.encode_array(ptr addrspace(1) %local, i32 0, ptr addrspace(1) %external, i32 0, i32 65, i1 true, i1 true)
  ret i32 %r
}

; CHECK-LABEL: @localDestination17(
; CHECK: load atomic i16
; CHECK: store atomic i8
; CHECK-NOT: @jeandle.encode_array
; CHECK: ret i32
; CAP-LABEL: @localDestination17(
; CAP: call hotspotcc i32 @jeandle.encode_array
define i32 @localDestination17(ptr addrspace(1) %external) {
  %local = call hotspotcc ptr addrspace(1) @jeandle.new_array(ptr null, i32 17, i32 50, i32 16, i32 100, i1 false, i1 false)
  %r = call hotspotcc i32 @jeandle.encode_array(ptr addrspace(1) %external, i32 0, ptr addrspace(1) %local, i32 0, i32 17, i1 false, i1 true)
  ret i32 %r
}

; CHECK-LABEL: @localDynamic(
; CHECK: call hotspotcc i32 @jeandle.encode_array
; CHECK: ret i32
define i32 @localDynamic(ptr addrspace(1) %external, i32 %n) {
  %local = call hotspotcc ptr addrspace(1) @jeandle.new_array(ptr null, i32 17, i32 50, i32 16, i32 100, i1 false, i1 false)
  %r = call hotspotcc i32 @jeandle.encode_array(ptr addrspace(1) %local, i32 0, ptr addrspace(1) %external, i32 0, i32 %n, i1 false, i1 true)
  ret i32 %r
}

; CHECK-LABEL: @localScan17(
; CHECK: load atomic i8
; CHECK: icmp slt i8
; CHECK-NOT: @jeandle.count_positives
; CHECK: ret i32
; CAP-LABEL: @localScan17(
; CAP: call hotspotcc i32 @jeandle.count_positives
define i32 @localScan17() {
  %local = call hotspotcc ptr addrspace(1) @jeandle.new_array(ptr null, i32 17, i32 33, i32 16, i32 100, i1 false, i1 false)
  %r = call hotspotcc i32 @jeandle.count_positives(ptr addrspace(1) %local, i32 0, i32 17)
  ret i32 %r
}

; CHECK-LABEL: @mixedSource17(
; CHECK: call hotspotcc i32 @jeandle.encode_array
; CHECK: ret i32
define i32 @mixedSource17(ptr addrspace(1) %external, ptr addrspace(1) %dst, i1 %select) {
  %local = call hotspotcc ptr addrspace(1) @jeandle.new_array(ptr null, i32 17, i32 50, i32 16, i32 100, i1 false, i1 false)
  %src = select i1 %select, ptr addrspace(1) %local, ptr addrspace(1) %external
  %r = call hotspotcc i32 @jeandle.encode_array(ptr addrspace(1) %src, i32 0, ptr addrspace(1) %dst, i32 0, i32 17, i1 false, i1 true)
  ret i32 %r
}

; CHECK-LABEL: @functionBudget(
; CHECK: load atomic i16
; CHECK: call hotspotcc i32 @jeandle.encode_array
; CHECK: ret i32
define i32 @functionBudget(ptr addrspace(1) %dst) {
  %src = call hotspotcc ptr addrspace(1) @jeandle.new_array(ptr null, i32 17, i32 50, i32 16, i32 100, i1 false, i1 false)
  %r0 = call hotspotcc i32 @jeandle.encode_array(ptr addrspace(1) %src, i32 0, ptr addrspace(1) %dst, i32 0, i32 17, i1 false, i1 true)
  %r1 = call hotspotcc i32 @jeandle.encode_array(ptr addrspace(1) %src, i32 0, ptr addrspace(1) %dst, i32 0, i32 17, i1 false, i1 true)
  %r2 = call hotspotcc i32 @jeandle.encode_array(ptr addrspace(1) %src, i32 0, ptr addrspace(1) %dst, i32 0, i32 17, i1 false, i1 true)
  %r3 = call hotspotcc i32 @jeandle.encode_array(ptr addrspace(1) %src, i32 0, ptr addrspace(1) %dst, i32 0, i32 17, i1 false, i1 true)
  %r4 = call hotspotcc i32 @jeandle.encode_array(ptr addrspace(1) %src, i32 0, ptr addrspace(1) %dst, i32 0, i32 17, i1 false, i1 true)
  %r5 = call hotspotcc i32 @jeandle.encode_array(ptr addrspace(1) %src, i32 0, ptr addrspace(1) %dst, i32 0, i32 17, i1 false, i1 true)
  %r6 = call hotspotcc i32 @jeandle.encode_array(ptr addrspace(1) %src, i32 0, ptr addrspace(1) %dst, i32 0, i32 17, i1 false, i1 true)
  %r7 = call hotspotcc i32 @jeandle.encode_array(ptr addrspace(1) %src, i32 0, ptr addrspace(1) %dst, i32 0, i32 17, i1 false, i1 true)
  %r8 = call hotspotcc i32 @jeandle.encode_array(ptr addrspace(1) %src, i32 0, ptr addrspace(1) %dst, i32 0, i32 17, i1 false, i1 true)
  %r9 = call hotspotcc i32 @jeandle.encode_array(ptr addrspace(1) %src, i32 0, ptr addrspace(1) %dst, i32 0, i32 17, i1 false, i1 true)
  %r10 = call hotspotcc i32 @jeandle.encode_array(ptr addrspace(1) %src, i32 0, ptr addrspace(1) %dst, i32 0, i32 17, i1 false, i1 true)
  %r11 = call hotspotcc i32 @jeandle.encode_array(ptr addrspace(1) %src, i32 0, ptr addrspace(1) %dst, i32 0, i32 17, i1 false, i1 true)
  %r12 = call hotspotcc i32 @jeandle.encode_array(ptr addrspace(1) %src, i32 0, ptr addrspace(1) %dst, i32 0, i32 17, i1 false, i1 true)
  %r13 = call hotspotcc i32 @jeandle.encode_array(ptr addrspace(1) %src, i32 0, ptr addrspace(1) %dst, i32 0, i32 17, i1 false, i1 true)
  %r14 = call hotspotcc i32 @jeandle.encode_array(ptr addrspace(1) %src, i32 0, ptr addrspace(1) %dst, i32 0, i32 17, i1 false, i1 true)
  %r15 = call hotspotcc i32 @jeandle.encode_array(ptr addrspace(1) %src, i32 0, ptr addrspace(1) %dst, i32 0, i32 17, i1 false, i1 true)
  %r16 = call hotspotcc i32 @jeandle.encode_array(ptr addrspace(1) %src, i32 0, ptr addrspace(1) %dst, i32 0, i32 17, i1 false, i1 true)
  %r17 = call hotspotcc i32 @jeandle.encode_array(ptr addrspace(1) %src, i32 0, ptr addrspace(1) %dst, i32 0, i32 17, i1 false, i1 true)
  %r18 = call hotspotcc i32 @jeandle.encode_array(ptr addrspace(1) %src, i32 0, ptr addrspace(1) %dst, i32 0, i32 17, i1 false, i1 true)
  %r19 = call hotspotcc i32 @jeandle.encode_array(ptr addrspace(1) %src, i32 0, ptr addrspace(1) %dst, i32 0, i32 17, i1 false, i1 true)
  %r20 = call hotspotcc i32 @jeandle.encode_array(ptr addrspace(1) %src, i32 0, ptr addrspace(1) %dst, i32 0, i32 17, i1 false, i1 true)
  %r21 = call hotspotcc i32 @jeandle.encode_array(ptr addrspace(1) %src, i32 0, ptr addrspace(1) %dst, i32 0, i32 17, i1 false, i1 true)
  %r22 = call hotspotcc i32 @jeandle.encode_array(ptr addrspace(1) %src, i32 0, ptr addrspace(1) %dst, i32 0, i32 17, i1 false, i1 true)
  %r23 = call hotspotcc i32 @jeandle.encode_array(ptr addrspace(1) %src, i32 0, ptr addrspace(1) %dst, i32 0, i32 17, i1 false, i1 true)
  %r24 = call hotspotcc i32 @jeandle.encode_array(ptr addrspace(1) %src, i32 0, ptr addrspace(1) %dst, i32 0, i32 17, i1 false, i1 true)
  %r25 = call hotspotcc i32 @jeandle.encode_array(ptr addrspace(1) %src, i32 0, ptr addrspace(1) %dst, i32 0, i32 17, i1 false, i1 true)
  %r26 = call hotspotcc i32 @jeandle.encode_array(ptr addrspace(1) %src, i32 0, ptr addrspace(1) %dst, i32 0, i32 17, i1 false, i1 true)
  %r27 = call hotspotcc i32 @jeandle.encode_array(ptr addrspace(1) %src, i32 0, ptr addrspace(1) %dst, i32 0, i32 17, i1 false, i1 true)
  %r28 = call hotspotcc i32 @jeandle.encode_array(ptr addrspace(1) %src, i32 0, ptr addrspace(1) %dst, i32 0, i32 17, i1 false, i1 true)
  %r29 = call hotspotcc i32 @jeandle.encode_array(ptr addrspace(1) %src, i32 0, ptr addrspace(1) %dst, i32 0, i32 17, i1 false, i1 true)
  %r30 = call hotspotcc i32 @jeandle.encode_array(ptr addrspace(1) %src, i32 0, ptr addrspace(1) %dst, i32 0, i32 17, i1 false, i1 true)
  %r31 = call hotspotcc i32 @jeandle.encode_array(ptr addrspace(1) %src, i32 0, ptr addrspace(1) %dst, i32 0, i32 17, i1 false, i1 true)
  ret i32 %r31
}
