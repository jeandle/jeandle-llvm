; REQUIRES: aarch64-registered-target
; RUN: opt -S -verify-each -jeandle-vm-callback-log=%S/../Inputs/pre-pea-high-tier-e2e.cblog -passes='jeandle<O3>' %s | FileCheck %s
; RUN: opt -S -verify-each -jeandle-vm-callback-log=%S/../Inputs/pre-pea-high-tier-e2e.cblog -jeandle-loop-strip-mining-iter=0 -passes='jeandle<O3>' %s | FileCheck %s

; A mutable-bound loop after poll expansion and GVN PRE. The slow path
; computes its thread argument before the deopt-state truncation, preventing
; simple common-prefix hoisting. Common the truncation across both edges
; before statepoint rewriting, and reuse it in the loop exit comparison.
; CHECK-LABEL: define hotspotcc i32 @stride_poll(
; CHECK: [[NEXT:%.*]] = add nuw nsw i64 {{%.*}}, 3
; CHECK: [[NARROW:%.*]] = trunc nuw i64 [[NEXT]] to i32
; CHECK-NOT: trunc {{.*}}i64 [[NEXT]] to i32
; CHECK: @llvm.experimental.gc.statepoint{{.*}}@safepoint_handler{{.*}}i32 [[NARROW]]
; CHECK-NOT: trunc {{.*}}i64 [[NEXT]] to i32
; CHECK: icmp slt i32 [[NARROW]],

target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i8:8:32-i16:16:32-i64:64-i128:128-n32:64-S128-Fn32-p3:32:32:32"
target triple = "aarch64-unknown-linux-gnu"

@jeandle.personality = external global ptr
@llvm.used = appending global [2 x ptr] [ptr @jeandle.pre_barrier, ptr @jeandle.post_barrier], section "llvm.metadata"
define private hotspotcc void @jeandle.pre_barrier(ptr addrspace(1) %addr) #5 { ret void }
define private hotspotcc void @jeandle.post_barrier(ptr addrspace(1) %addr, ptr addrspace(1) %oop) #5 { ret void }

; Function Attrs: mustprogress nofree noinline norecurse nosync nounwind willreturn memory(none)
define private hotspotcc ptr addrspace(1) @jeandle.decode_heap_oop(ptr addrspace(3) %narrow) #0 {
entry:
  %bits = ptrtoint ptr addrspace(3) %narrow to i32
  %wide = zext i32 %bits to i64
  %oop = inttoptr i64 %wide to ptr addrspace(1)
  ret ptr addrspace(1) %oop
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(read)
declare i64 @llvm.read_register.i64(metadata) #1

declare hotspotcc void @safepoint_handler(ptr) local_unnamed_addr

define hotspotcc i32 @stride_poll(ptr addrspace(1) noundef nonnull readonly captures(none) %0) local_unnamed_addr #2 gc "hotspotgc" personality ptr @jeandle.personality {
entry:
  %OrigPcSlot = alloca i64, align 8
  %1 = getelementptr inbounds nuw i8, ptr addrspace(1) %0, i64 12
  %2 = load atomic i32, ptr addrspace(1) %1 unordered, align 4, !noundef !5
  %.not17 = icmp sgt i32 %2, 0
  br i1 %.not17, label %bci_14_null_check_pass.preheader, label %bci_27, !prof !6

bci_14_null_check_pass.preheader:                 ; preds = %entry
  %3 = getelementptr inbounds nuw i8, ptr addrspace(1) %0, i64 20
  br label %bci_14_null_check_pass

bci_27:                                           ; preds = %jeandle.safepoint_poll.exit, %entry
  %.lcssa9 = phi i32 [ 0, %entry ], [ %17, %jeandle.safepoint_poll.exit ]
  %4 = load volatile i64, ptr addrspace(2) inttoptr (i64 1096 to ptr addrspace(2)), align 8
  %5 = and i64 %4, 1
  %.not.i83 = icmp eq i64 %5, 0
  br i1 %.not.i83, label %jeandle.safepoint_poll.exit85, label %do_safepoint.i84

do_safepoint.i84:                                 ; preds = %bci_27
  %6 = call i64 @llvm.read_register.i64(metadata !0)
  %7 = inttoptr i64 %6 to ptr
  call hotspotcc void @safepoint_handler(ptr %7) #3 [ "deopt"(i64 0, i32 28, i32 28, i64 99, i32 0, i64 4294967395, i32 0, i64 8589934691, i32 0, i64 65546, i32 %.lcssa9, i64 327695, ptr %OrigPcSlot) ]
  br label %jeandle.safepoint_poll.exit85

jeandle.safepoint_poll.exit85:                    ; preds = %do_safepoint.i84, %bci_27
  ret i32 %.lcssa9

bci_14_null_check_pass:                           ; preds = %jeandle.safepoint_poll.exit, %bci_14_null_check_pass.preheader
  %8 = phi i32 [ %2, %bci_14_null_check_pass.preheader ], [ %23, %jeandle.safepoint_poll.exit ]
  %indvars.iv = phi i64 [ 0, %bci_14_null_check_pass.preheader ], [ %indvars.iv.next, %jeandle.safepoint_poll.exit ]
  %9 = phi i32 [ 0, %bci_14_null_check_pass.preheader ], [ %17, %jeandle.safepoint_poll.exit ]
  %10 = load atomic ptr addrspace(3), ptr addrspace(1) %3 unordered, align 4, !noundef !5
  %11 = call hotspotcc ptr addrspace(1) @jeandle.decode_heap_oop(ptr addrspace(3) %10)
  %.not46.not = icmp eq ptr addrspace(3) %10, null
  br i1 %.not46.not, label %bci_18_null_check_fail, label %bci_18_null_check_pass, !prof !8, !make.implicit !5

bci_18_null_check_pass:                           ; preds = %bci_14_null_check_pass
  %length_addr.i = getelementptr inbounds nuw i8, ptr addrspace(1) %11, i64 12
  %length.i = load atomic i32, ptr addrspace(1) %length_addr.i unordered, align 4, !range !9
  %12 = zext nneg i32 %length.i to i64
  %13 = icmp samesign ult i64 %indvars.iv, %12
  br i1 %13, label %bci_18_boundary_check_pass, label %bci_18_boundary_check_fail, !prof !10

bci_18_null_check_fail:                           ; preds = %bci_14_null_check_pass
  %14 = trunc nuw i64 %indvars.iv to i32
  %15 = call hotspotcc i32 (...) @llvm.experimental.deoptimize.i32(i32 -10) #4 [ "deopt"(i64 1, i32 18, i32 18, i64 12, ptr addrspace(1) %0, i64 4294967395, i32 0, i64 8589934602, i32 %14, i64 65546, i32 %9, i64 4295032844, ptr addrspace(1) null, i64 8590000138, i32 %14, i64 327695, ptr %OrigPcSlot) ]
  ret i32 %15

bci_18_boundary_check_pass:                       ; preds = %bci_18_null_check_pass
  %array_element_base = getelementptr inbounds nuw i8, ptr addrspace(1) %11, i64 16
  %array_element_address = getelementptr inbounds nuw i32, ptr addrspace(1) %array_element_base, i64 %indvars.iv
  %16 = load atomic i32, ptr addrspace(1) %array_element_address unordered, align 4, !noundef !5
  %17 = add i32 %16, %9
  %indvars.iv.next = add nuw nsw i64 %indvars.iv, 3
  %18 = load volatile i64, ptr addrspace(2) inttoptr (i64 1096 to ptr addrspace(2)), align 8
  %19 = and i64 %18, 1
  %.not.i = icmp eq i64 %19, 0
  br i1 %.not.i, label %bci_18_boundary_check_pass.jeandle.safepoint_poll.exit_crit_edge, label %do_safepoint.i

bci_18_boundary_check_pass.jeandle.safepoint_poll.exit_crit_edge: ; preds = %bci_18_boundary_check_pass
  %.pre108 = trunc nuw i64 %indvars.iv.next to i32
  br label %jeandle.safepoint_poll.exit

do_safepoint.i:                                   ; preds = %bci_18_boundary_check_pass
  %20 = call i64 @llvm.read_register.i64(metadata !0)
  %21 = inttoptr i64 %20 to ptr
  %22 = trunc nuw i64 %indvars.iv.next to i32
  call hotspotcc void @safepoint_handler(ptr %21) #3 [ "deopt"(i64 0, i32 24, i32 24, i64 12, ptr addrspace(1) %0, i64 4294967306, i32 %17, i64 8589934602, i32 %22, i64 327695, ptr %OrigPcSlot) ]
  %.pre = load atomic i32, ptr addrspace(1) %1 unordered, align 4
  br label %jeandle.safepoint_poll.exit

jeandle.safepoint_poll.exit:                      ; preds = %do_safepoint.i, %bci_18_boundary_check_pass.jeandle.safepoint_poll.exit_crit_edge
  %.pre-phi = phi i32 [ %.pre108, %bci_18_boundary_check_pass.jeandle.safepoint_poll.exit_crit_edge ], [ %22, %do_safepoint.i ]
  %23 = phi i32 [ %8, %bci_18_boundary_check_pass.jeandle.safepoint_poll.exit_crit_edge ], [ %.pre, %do_safepoint.i ]
  %.not = icmp slt i32 %.pre-phi, %23
  br i1 %.not, label %bci_14_null_check_pass, label %bci_27, !prof !11

bci_18_boundary_check_fail:                       ; preds = %bci_18_null_check_pass
  %24 = trunc nuw i64 %indvars.iv to i32
  %25 = call hotspotcc i32 (...) @llvm.experimental.deoptimize.i32(i32 -26) [ "deopt"(i64 1, i32 18, i32 18, i64 12, ptr addrspace(1) %0, i64 4294967395, i32 0, i64 8589934602, i32 %24, i64 65546, i32 %9, i64 4295032844, ptr addrspace(1) %11, i64 8590000138, i32 %24, i64 327695, ptr %OrigPcSlot) ]
  ret i32 %25
}

declare hotspotcc i32 @llvm.experimental.deoptimize.i32(...)

attributes #0 = { mustprogress nofree noinline norecurse nosync nounwind willreturn memory(none) "gc-leaf-function" "lower-phase"="9" }
attributes #1 = { nocallback nofree nosync nounwind willreturn memory(read) }
attributes #2 = { "disable-tail-calls"="true" "no-realign-stack" "use-compressed-oops" }
attributes #3 = { nounwind }
attributes #4 = { "jeandle-implicit-null-check" }
attributes #5 = { noinline "lower-phase"="9" }

!current-thread = !{!0}
!stack-pointer = !{!1}
!heap-base = !{!2}
!static-call-patch-size = !{!3}
!dynamic-call-patch-size = !{!4}
!java-method-compilation = !{}

!0 = !{!"x28"}
!1 = !{!"sp"}
!2 = !{!"x27"}
!3 = !{i32 4}
!4 = !{i32 16}
!5 = !{}
!6 = !{!"branch_weights", i32 127, i32 1}
!8 = !{!"branch_weights", i32 1, i32 1048575}
!9 = !{i32 0, i32 -2147483648}
!10 = !{!"branch_weights", i32 1048575, i32 1}
!11 = !{!"branch_weights", i32 130945, i32 127}
