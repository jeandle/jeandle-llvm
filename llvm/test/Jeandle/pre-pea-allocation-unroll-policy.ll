; RUN: opt --jeandle -jeandle-inline=off -jeandle-vm-callback-log=%S/partial-escape/Inputs/773_copy_fold_concrete_src.cblog -unroll-threshold=1 -jeandle-verify-safepoint-coverage=off -print-after-all -print-module-scope -filter-print-funcs=hint_array -disable-output %s 2>&1 | FileCheck %s --check-prefix=HINT
; RUN: opt --jeandle -jeandle-inline=off -jeandle-vm-callback-log=%S/partial-escape/Inputs/773_copy_fold_concrete_src.cblog -unroll-threshold=1 -jeandle-verify-safepoint-coverage=off -print-after-all -print-module-scope -filter-print-funcs=cost_limit -disable-output %s 2>&1 | FileCheck %s --check-prefix=LIMIT
; RUN: opt --jeandle -jeandle-inline=off -jeandle-vm-callback-log=%S/partial-escape/Inputs/773_copy_fold_concrete_src.cblog -unroll-threshold=1 -jeandle-verify-safepoint-coverage=off -print-after-all -print-module-scope -filter-print-funcs=no_array -disable-output %s 2>&1 | FileCheck %s --check-prefix=NOARRAY
; RUN: opt --jeandle -jeandle-inline=off -jeandle-vm-callback-log=%S/partial-escape/Inputs/773_copy_fold_concrete_src.cblog -unroll-threshold=1 -jeandle-verify-safepoint-coverage=off -print-after-all -print-module-scope -filter-print-funcs=disabled -disable-output %s 2>&1 | FileCheck %s --check-prefix=DISABLE

; A deliberately low ordinary threshold isolates the extra allowance for
; allocation consumers. Other loops keep LLVM's ordinary policy and explicit
; user disables remain effective.
; HINT: IR Dump After jeandle::PrePEAAllocationUnrollHints on hint_array
; HINT: define hotspotcc i64 @hint_array
; HINT: !"llvm.loop.unroll.full"
; LIMIT: IR Dump After jeandle::PrePEAAllocationUnrollHints on cost_limit
; LIMIT: define hotspotcc i64 @cost_limit
; LIMIT-NOT: !"llvm.loop.unroll.full"
; NOARRAY: IR Dump After jeandle::PrePEAAllocationUnrollHints on no_array
; NOARRAY: define hotspotcc i64 @no_array
; NOARRAY-NOT: !"llvm.loop.unroll.full"
; DISABLE: IR Dump After jeandle::PrePEAAllocationUnrollHints on disabled
; DISABLE: define hotspotcc i64 @disabled
; DISABLE-NOT: !"llvm.loop.unroll.full"
; DISABLE: !"llvm.loop.unroll.disable"

target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128-p3:32:32:32"
target triple = "x86_64-unknown-linux-gnu"
@jeandle.personality = global ptr null
@opaque = external global i64

declare void @jeandle.pre_barrier(ptr addrspace(1), ptr addrspace(1))
declare void @jeandle.post_barrier(ptr addrspace(1), ptr addrspace(1))
declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32, i1, i1)

define hotspotcc i64 @hint_array(ptr addrspace(1) %input) #0 gc "hotspotgc" personality ptr @jeandle.personality {
entry:
  %array = call hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 12345 to ptr), i32 64, i32 272, i32 16, i32 1048576, i1 false, i1 false)
  br label %loop
loop:
  %i = phi i64 [ 0, %entry ], [ %next, %loop ]
  %sum = phi i64 [ 0, %entry ], [ %added, %loop ]
  %base = getelementptr inbounds i8, ptr addrspace(1) %array, i64 16
  %ptr = getelementptr inbounds i32, ptr addrspace(1) %base, i64 %i
  %value = load atomic i32, ptr addrspace(1) %ptr unordered, align 4
  %wide = sext i32 %value to i64
  %added = add i64 %sum, %wide
  %next = add nuw nsw i64 %i, 1
  %done = icmp eq i64 %next, 64
  br i1 %done, label %exit, label %loop
exit:
  ret i64 %added
}

define hotspotcc i64 @cost_limit(ptr addrspace(1) %input) #0 gc "hotspotgc" personality ptr @jeandle.personality {
entry:
  %array = call hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 12345 to ptr), i32 64, i32 272, i32 16, i32 1048576, i1 false, i1 false)
  br label %loop
loop:
  %i = phi i64 [ 0, %entry ], [ %next, %loop ]
  %sum = phi i64 [ 0, %entry ], [ %added, %loop ]
  %base = getelementptr inbounds i8, ptr addrspace(1) %array, i64 16
  %ptr = getelementptr inbounds i32, ptr addrspace(1) %base, i64 %i
  %value = load atomic i32, ptr addrspace(1) %ptr unordered, align 4
  %wide = sext i32 %value to i64
  %opaque0 = load volatile i64, ptr @opaque, align 8
  %mix0 = xor i64 %wide, %opaque0
  %opaque1 = load volatile i64, ptr @opaque, align 8
  %mix1 = xor i64 %mix0, %opaque1
  %opaque2 = load volatile i64, ptr @opaque, align 8
  %mix2 = xor i64 %mix1, %opaque2
  %opaque3 = load volatile i64, ptr @opaque, align 8
  %mix3 = xor i64 %mix2, %opaque3
  %opaque4 = load volatile i64, ptr @opaque, align 8
  %mix4 = xor i64 %mix3, %opaque4
  %opaque5 = load volatile i64, ptr @opaque, align 8
  %mix5 = xor i64 %mix4, %opaque5
  %opaque6 = load volatile i64, ptr @opaque, align 8
  %mix6 = xor i64 %mix5, %opaque6
  %opaque7 = load volatile i64, ptr @opaque, align 8
  %mix7 = xor i64 %mix6, %opaque7
  %opaque8 = load volatile i64, ptr @opaque, align 8
  %mix8 = xor i64 %mix7, %opaque8
  %opaque9 = load volatile i64, ptr @opaque, align 8
  %mix9 = xor i64 %mix8, %opaque9
  %opaque10 = load volatile i64, ptr @opaque, align 8
  %mix10 = xor i64 %mix9, %opaque10
  %opaque11 = load volatile i64, ptr @opaque, align 8
  %mix11 = xor i64 %mix10, %opaque11
  %opaque12 = load volatile i64, ptr @opaque, align 8
  %mix12 = xor i64 %mix11, %opaque12
  %opaque13 = load volatile i64, ptr @opaque, align 8
  %mix13 = xor i64 %mix12, %opaque13
  %opaque14 = load volatile i64, ptr @opaque, align 8
  %mix14 = xor i64 %mix13, %opaque14
  %opaque15 = load volatile i64, ptr @opaque, align 8
  %mix15 = xor i64 %mix14, %opaque15
  %opaque16 = load volatile i64, ptr @opaque, align 8
  %mix16 = xor i64 %mix15, %opaque16
  %opaque17 = load volatile i64, ptr @opaque, align 8
  %mix17 = xor i64 %mix16, %opaque17
  %opaque18 = load volatile i64, ptr @opaque, align 8
  %mix18 = xor i64 %mix17, %opaque18
  %opaque19 = load volatile i64, ptr @opaque, align 8
  %mix19 = xor i64 %mix18, %opaque19
  %opaque20 = load volatile i64, ptr @opaque, align 8
  %mix20 = xor i64 %mix19, %opaque20
  %opaque21 = load volatile i64, ptr @opaque, align 8
  %mix21 = xor i64 %mix20, %opaque21
  %opaque22 = load volatile i64, ptr @opaque, align 8
  %mix22 = xor i64 %mix21, %opaque22
  %opaque23 = load volatile i64, ptr @opaque, align 8
  %mix23 = xor i64 %mix22, %opaque23
  %opaque24 = load volatile i64, ptr @opaque, align 8
  %mix24 = xor i64 %mix23, %opaque24
  %opaque25 = load volatile i64, ptr @opaque, align 8
  %mix25 = xor i64 %mix24, %opaque25
  %opaque26 = load volatile i64, ptr @opaque, align 8
  %mix26 = xor i64 %mix25, %opaque26
  %opaque27 = load volatile i64, ptr @opaque, align 8
  %mix27 = xor i64 %mix26, %opaque27
  %opaque28 = load volatile i64, ptr @opaque, align 8
  %mix28 = xor i64 %mix27, %opaque28
  %opaque29 = load volatile i64, ptr @opaque, align 8
  %mix29 = xor i64 %mix28, %opaque29
  %added = add i64 %sum, %mix29
  %next = add nuw nsw i64 %i, 1
  %done = icmp eq i64 %next, 64
  br i1 %done, label %exit, label %loop
exit:
  ret i64 %added
}

define hotspotcc i64 @no_array(ptr addrspace(1) %input) #0 gc "hotspotgc" personality ptr @jeandle.personality {
entry:
  br label %loop
loop:
  %i = phi i64 [ 0, %entry ], [ %next, %loop ]
  %sum = phi i64 [ 0, %entry ], [ %added, %loop ]
  %base = getelementptr inbounds i8, ptr addrspace(1) %input, i64 16
  %ptr = getelementptr inbounds i32, ptr addrspace(1) %base, i64 %i
  %value = load atomic i32, ptr addrspace(1) %ptr unordered, align 4
  %wide = sext i32 %value to i64
  %added = add i64 %sum, %wide
  %next = add nuw nsw i64 %i, 1
  %done = icmp eq i64 %next, 64
  br i1 %done, label %exit, label %loop
exit:
  ret i64 %added
}

define hotspotcc i64 @disabled(ptr addrspace(1) %input) #0 gc "hotspotgc" personality ptr @jeandle.personality {
entry:
  %array = call hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 12345 to ptr), i32 64, i32 272, i32 16, i32 1048576, i1 false, i1 false)
  br label %loop
loop:
  %i = phi i64 [ 0, %entry ], [ %next, %loop ]
  %sum = phi i64 [ 0, %entry ], [ %added, %loop ]
  %base = getelementptr inbounds i8, ptr addrspace(1) %array, i64 16
  %ptr = getelementptr inbounds i32, ptr addrspace(1) %base, i64 %i
  %value = load atomic i32, ptr addrspace(1) %ptr unordered, align 4
  %wide = sext i32 %value to i64
  %added = add i64 %sum, %wide
  %next = add nuw nsw i64 %i, 1
  %done = icmp eq i64 %next, 64
  br i1 %done, label %exit, label %loop, !llvm.loop !0
exit:
  ret i64 %added
}

attributes #0 = { "java-method"="0" }
!java-method-compilation = !{}
!0 = distinct !{!0, !1}
!1 = !{!"llvm.loop.unroll.disable"}
