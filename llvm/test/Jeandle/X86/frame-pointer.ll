; RUN: llc -O3 -mtriple=x86_64-linux-gnu < %s | FileCheck %s

; CHECK: pushq	%rbp
; CHECK-NEXT:	subq	$32, %rsp
; CHECK-NEXT: .cfi_def_cfa_offset 48
; CHECK-NEXT: # kill: def $esi killed $esi def $rsi
; CHECK-NEXT: testl	%esi, %esi
; CHECK: movl	%esi, %eax
; CHECK-NEXT: addq	$32, %rsp
; CHECK-NEXT: .cfi_def_cfa_offset 8
; CHECK-NEXT: popq	%rbp
; CHECK-NEXT: .cfi_def_cfa_offset 0
; CHECK-NEXT: retq
define hotspotcc i32 @"Main_testEpilogProlog_(I)I"(i32 %0) local_unnamed_addr #0 gc "hotspotgc" {
entry:
  %1 = icmp sgt i32 %0, 0
  br i1 %1, label %bci_18, label %common.ret

common.ret:                                       ; preds = %bci_18, %entry
  %common.ret.op = phi i32 [ %0, %entry ], [ %9, %bci_18 ]
  ret i32 %common.ret.op

bci_18:                                           ; preds = %entry, %bci_18
  %2 = phi i32 [ %10, %bci_18 ], [ 0, %entry ]
  %3 = phi i32 [ %6, %bci_18 ], [ %0, %entry ]
  %4 = phi i32 [ %9, %bci_18 ], [ %0, %entry ]
  %5 = add i32 %2, %4
  %6 = add i32 %3, 1
  %7 = add i32 %5, %6
  %statepoint_token = tail call hotspotcc token (i64, i32, ptr, i32, i32, ...) @llvm.experimental.gc.statepoint.p0(i64 0, i32 5, ptr elementtype(i32 ()) @"Main_getInt_()I", i32 0, i32 0, i32 0, i32 0)
  %8 = call i32 @llvm.experimental.gc.result.i32(token %statepoint_token)
  %9 = add i32 %7, %8
  %10 = add nuw nsw i32 %2, 1
  %exitcond.not = icmp eq i32 %10, %0
  br i1 %exitcond.not, label %common.ret, label %bci_18
}

declare hotspotcc i32 @"Main_getInt_()I"() local_unnamed_addr #1 gc "hotspotgc"

declare token @llvm.experimental.gc.statepoint.p0(i64 immarg, i32 immarg, ptr, i32 immarg, i32 immarg, ...)

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(none)
declare i32 @llvm.experimental.gc.result.i32(token) #2

attributes #0 = { "java-method" "use-compressed-oops" }
attributes #1 = { "use-compressed-oops" }
attributes #2 = { nocallback nofree nosync nounwind willreturn memory(none) }
