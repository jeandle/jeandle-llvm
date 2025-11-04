; RUN: opt -S --passes=-S -passes="java-operation-lower<phase=0>,insert-gc-barriers,java-operation-lower<phase=1>" %s 2>&1 | FileCheck %s

; CHECK: %derived.pointer = getelementptr inbounds i8, ptr addrspace(1) %dst, i64 24
; CHECK-NEXT: store atomic ptr addrspace(1) %src, ptr addrspace(1) %derived.pointer unordered, align 8
; CHECK-NEXT: %base.pointer = call ptr addrspace(1) @llvm.experimental.gc.get.pointer.base.p1.p1(ptr addrspace(1) %derived.pointer)
; CHECK-NEXT: %0 = ptrtoint ptr addrspace(1) %base.pointer to i64
; CHECK-NEXT: %1 = lshr i64 %0, 9
; CHECK-NEXT: %2 = getelementptr inbounds i8, ptr inttoptr (i64 139709660639232 to ptr), i64 %1
; CHECK-NEXT: store atomic i8 0, ptr %2 unordered, align 1

define private hotspotcc void @jeandle.card_table_barrier(ptr addrspace(1) %addr) #0 {
entry:
  %0 = ptrtoint ptr addrspace(1) %addr to i64
  %1 = lshr i64 %0, 9
  %2 = getelementptr inbounds i8, ptr inttoptr (i64 139709660639232 to ptr), i64 %1
  store atomic i8 0, ptr %2 unordered, align 1
  ret void
}

define hotspotcc void @test_card_table_barrier(ptr addrspace(1) %dst, ptr addrspace(1) %src) gc "hotspotgc" {
entry:                                        ; preds = %entry
  %derived.pointer = getelementptr inbounds i8, ptr addrspace(1) %dst, i64 24
  store atomic ptr addrspace(1) %src, ptr addrspace(1) %derived.pointer unordered, align 8
  ret void

}

attributes #0 = { noinline "lower-phase"="1" }

!java_method_compilation = !{}
