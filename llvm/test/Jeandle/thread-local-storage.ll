; RUN: opt -S --passes=tls-pointer-rewrite %s 2>&1 | FileCheck %s

; CHECK: %0 = call i64 @llvm.read_register.i64(metadata !0)
; CHECK-NEXT: %.address = add i64 1160, %0
; CHECK-NEXT: %.tls.ptr = inttoptr i64 %.address to ptr addrspace(2)
; CHECK-NEXT: store i64 0, ptr addrspace(2) %.tls.ptr, align 8
; CHECK-NEXT: %1 = load i64, ptr addrspace(2) %.tls.ptr, align 8
; CHECK-NEXT: %2 = inttoptr i64 984 to ptr addrspace(2)
; CHECK-NEXT: %.offset = ptrtoint ptr addrspace(2) %2 to i64
; CHECK-NEXT: %.address1 = add i64 %.offset, %0
; CHECK-NEXT: %.tls.ptr2 = inttoptr i64 %.address1 to ptr addrspace(2)
; CHECK-NEXT: store i64 %1, ptr addrspace(2) %.tls.ptr2, align 8
; CHECK-NEXT: store i64 0, ptr addrspace(2) %.tls.ptr2, align 8
; CHECK-NEXT: %3 = icmp eq i64 %1, 0
; CHECK-NEXT: br i1 %3, label %br1, label %br2

; CHECK: return:                                           ; preds = %br2, %br1
; CHECK-NEXT:   %6 = phi ptr addrspace(2) [ %.tls.ptr5, %br1 ], [ %.tls.ptr8, %br2 ]
; CHECK-NEXT:   %7 = load i64, ptr addrspace(2) %6, align 8

define hotspotcc i64 @thread_local_storage() {
entry:
  store i64 0, ptr addrspace(2) inttoptr (i64 1160 to ptr addrspace(2)), align 8
  %0 = load i64, ptr addrspace(2) inttoptr (i64 1160 to ptr addrspace(2)), align 8
  %1 = inttoptr i64 984 to ptr addrspace(2)
  store i64 %0, ptr addrspace(2) %1, align 8
  store i64 0, ptr addrspace(2) %1, align 8
  %2 = icmp eq i64 %0, 0
  br i1 %2, label %br1, label %br2

br1:
  %3 = inttoptr i64 1 to ptr addrspace(2)
  br label %return

br2:
  %4 = inttoptr i64 2 to ptr addrspace(2)
  br label %return

return:
  %5 = phi ptr addrspace(2) [ %3, %br1 ], [ %4, %br2 ]
  %6 = load i64, ptr addrspace(2) %5, align 8
  ret i64 %6
}

!current_thread = !{!0}

!0 = !{!"r15"}
