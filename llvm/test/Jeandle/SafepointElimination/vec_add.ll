; RUN: opt -passes=safepoint-elimination -S < %s | FileCheck %s
; origin java code
;  static void vec_add(int[] a, int[] b, int[] c) {
;    for (int i=0;i<100;i++) {
;      c[i] = a[i] + b[i];
;    }
;  }

@jeandle.personality = global ptr null
declare void @uncommon_trap(i32)
declare hotspotcc i32 @jeandle.arraylength(ptr addrspace(1))
declare hotspotcc void @jeandle.safepoint_poll()

; Function Attrs: nocf_check
define hotspotcc void @"TestLoop_vec_add([I[I[I)V"(ptr addrspace(1) %0, ptr addrspace(1) %1, ptr addrspace(1) %2) #4 gc "hotspotgc" personality ptr @jeandle.personality {
entry:
  br label %bci_0

bci_0:                                            ; preds = %entry
  br label %bci_2

bci_2:                                            ; preds = %bci_17_boundary_check_pass, %bci_0
  %3 = phi ptr addrspace(1) [ %0, %bci_0 ], [ %3, %bci_17_boundary_check_pass ]
  %4 = phi ptr addrspace(1) [ %1, %bci_0 ], [ %4, %bci_17_boundary_check_pass ]
  %5 = phi ptr addrspace(1) [ %2, %bci_0 ], [ %5, %bci_17_boundary_check_pass ]
  %6 = phi i32 [ 0, %bci_0 ], [ %20, %bci_17_boundary_check_pass ]
  %7 = icmp sge i32 %6, 100
  br i1 %7, label %bci_24, label %bci_8

bci_8:                                            ; preds = %bci_2
  %8 = icmp eq ptr addrspace(1) %3, null
  br i1 %8, label %bci_12_null_check_fail, label %bci_12_null_check_pass, !make.implicit !2

bci_24:                                           ; preds = %bci_2
  ret void

bci_12_null_check_pass:                           ; preds = %bci_8
  %9 = call hotspotcc i32 @jeandle.arraylength(ptr addrspace(1) %3)
  %10 = icmp uge i32 %6, %9
  br i1 %10, label %bci_12_boundary_check_fail, label %bci_12_boundary_check_pass

bci_12_null_check_fail:                           ; preds = %bci_8
  call hotspotcc void @uncommon_trap(i32 -10) #5 [ "deopt"(i32 12, i64 12, ptr addrspace(1) %3, i64 4294967308, ptr addrspace(1) %4, i64 8589934604, ptr addrspace(1) %5, i64 12884901898, i32 %6, i64 65548, ptr addrspace(1) %5, i64 4295032842, i32 %6, i64 8590000140, ptr addrspace(1) %3, i64 12884967434, i32 %6) ]
  unreachable

bci_12_boundary_check_pass:                       ; preds = %bci_12_null_check_pass
  %array_element_base = getelementptr inbounds i8, ptr addrspace(1) %3, i32 24
  %array_element_address = getelementptr inbounds i32, ptr addrspace(1) %array_element_base, i32 %6
  %11 = load atomic i32, ptr addrspace(1) %array_element_address unordered, align 4
  %12 = icmp eq ptr addrspace(1) %4, null
  br i1 %12, label %bci_15_null_check_fail, label %bci_15_null_check_pass, !make.implicit !2

bci_12_boundary_check_fail:                       ; preds = %bci_12_null_check_pass
  call hotspotcc void @uncommon_trap(i32 -26) #5 [ "deopt"(i32 12, i64 12, ptr addrspace(1) %3, i64 4294967308, ptr addrspace(1) %4, i64 8589934604, ptr addrspace(1) %5, i64 12884901898, i32 %6, i64 65548, ptr addrspace(1) %5, i64 4295032842, i32 %6, i64 8590000140, ptr addrspace(1) %3, i64 12884967434, i32 %6) ]
  unreachable

bci_15_null_check_pass:                           ; preds = %bci_12_boundary_check_pass
  %13 = call hotspotcc i32 @jeandle.arraylength(ptr addrspace(1) %4)
  %14 = icmp uge i32 %6, %13
  br i1 %14, label %bci_15_boundary_check_fail, label %bci_15_boundary_check_pass

bci_15_null_check_fail:                           ; preds = %bci_12_boundary_check_pass
  call hotspotcc void @uncommon_trap(i32 -10) #5 [ "deopt"(i32 15, i64 12, ptr addrspace(1) %3, i64 4294967308, ptr addrspace(1) %4, i64 8589934604, ptr addrspace(1) %5, i64 12884901898, i32 %6, i64 65548, ptr addrspace(1) %5, i64 4295032842, i32 %6, i64 8590000138, i32 %11, i64 12884967436, ptr addrspace(1) %4, i64 17179934730, i32 %6) ]
  unreachable

bci_15_boundary_check_pass:                       ; preds = %bci_15_null_check_pass
  %array_element_base1 = getelementptr inbounds i8, ptr addrspace(1) %4, i32 24
  %array_element_address2 = getelementptr inbounds i32, ptr addrspace(1) %array_element_base1, i32 %6
  %15 = load atomic i32, ptr addrspace(1) %array_element_address2 unordered, align 4
  %16 = add i32 %11, %15
  %17 = icmp eq ptr addrspace(1) %5, null
  br i1 %17, label %bci_17_null_check_fail, label %bci_17_null_check_pass, !make.implicit !2

bci_15_boundary_check_fail:                       ; preds = %bci_15_null_check_pass
  call hotspotcc void @uncommon_trap(i32 -26) #5 [ "deopt"(i32 15, i64 12, ptr addrspace(1) %3, i64 4294967308, ptr addrspace(1) %4, i64 8589934604, ptr addrspace(1) %5, i64 12884901898, i32 %6, i64 65548, ptr addrspace(1) %5, i64 4295032842, i32 %6, i64 8590000138, i32 %11, i64 12884967436, ptr addrspace(1) %4, i64 17179934730, i32 %6) ]
  unreachable

bci_17_null_check_pass:                           ; preds = %bci_15_boundary_check_pass
  %18 = call hotspotcc i32 @jeandle.arraylength(ptr addrspace(1) %5)
  %19 = icmp uge i32 %6, %18
  br i1 %19, label %bci_17_boundary_check_fail, label %bci_17_boundary_check_pass

bci_17_null_check_fail:                           ; preds = %bci_15_boundary_check_pass
  call hotspotcc void @uncommon_trap(i32 -10) #5 [ "deopt"(i32 17, i64 12, ptr addrspace(1) %3, i64 4294967308, ptr addrspace(1) %4, i64 8589934604, ptr addrspace(1) %5, i64 12884901898, i32 %6, i64 65548, ptr addrspace(1) %5, i64 4295032842, i32 %6, i64 8590000138, i32 %16) ]
  unreachable

bci_17_boundary_check_pass:                       ; preds = %bci_17_null_check_pass
  %array_element_base3 = getelementptr inbounds i8, ptr addrspace(1) %5, i32 24
  %array_element_address4 = getelementptr inbounds i32, ptr addrspace(1) %array_element_base3, i32 %6
  store atomic i32 %16, ptr addrspace(1) %array_element_address4 unordered, align 4
  %20 = add i32 %6, 1
  call hotspotcc void @jeandle.safepoint_poll()
  br label %bci_2

bci_17_boundary_check_fail:                       ; preds = %bci_17_null_check_pass
  call hotspotcc void @uncommon_trap(i32 -26) #5 [ "deopt"(i32 17, i64 12, ptr addrspace(1) %3, i64 4294967308, ptr addrspace(1) %4, i64 8589934604, ptr addrspace(1) %5, i64 12884901898, i32 %6, i64 65548, ptr addrspace(1) %5, i64 4295032842, i32 %6, i64 8590000138, i32 %16) ]
  unreachable
}

attributes #0 = { noinline "lower-phase"="0" }
attributes #1 = { "lower-phase"="0" }
attributes #2 = { noinline "lower-phase"="1" }
attributes #3 = { nocallback nofree nosync nounwind willreturn memory(read) }
attributes #4 = { nocf_check "disable-tail-calls"="true" }
attributes #5 = { noreturn }

!current_thread = !{!0}
!stack_pointer = !{!1}
!java-method-compilation = !{}

!0 = !{!"r15"}
!1 = !{!"rsp"}
!2 = !{}

; CHECK:     bci_17_boundary_check_pass:
; CHECK-NOT: call hotspotcc void @jeandle.safepoint_poll()
