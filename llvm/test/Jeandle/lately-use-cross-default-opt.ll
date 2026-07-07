; RUN: opt -S -passes="java-operation-lower<phase=0>,default<O3>,insert-gc-barriers" %s 2>&1 | FileCheck -check-prefix=CHECK-USE %s
; RUN: opt -S -passes="java-operation-lower<phase=0>,default<O3>,insert-gc-barriers,java-operation-lower<phase=1>,java-operation-deletion" %s 2>&1 | FileCheck -check-prefix=CHECK-ERASE %s

; CHECK-USE: @llvm.used = appending global
; CHECK-USE: define hotspotcc void @test_gc_write_barrier
; CHECK-USE: store atomic ptr addrspace(1) %src, ptr addrspace(1) %derived.pointer
; CHECK-USE-NEXT: %base.pointer = call ptr addrspace(1) @llvm.experimental.gc.get.pointer.base.p1.p1(ptr addrspace(1) %derived.pointer)
; CHECK-USE-NEXT: call hotspotcc void @jeandle.post_barrier(ptr addrspace(1) %base.pointer, ptr addrspace(1) %src)

; CHECK-ERASE-NOT: @llvm.used = appending global
; CHECK-ERASE-NOT: @jeandle.card_table_barrier
; CHECK-ERASE-NOT: @jeandle.pre_barrier
; CHECK-ERASE-NOT: @jeandle.post_barrier

@llvm.used = appending global [3 x ptr] [ptr @jeandle.card_table_barrier, ptr @jeandle.pre_barrier, ptr @jeandle.post_barrier], section "llvm.metadata"

define private hotspotcc void @jeandle.card_table_barrier(ptr addrspace(1) %addr) #0 {
entry:
  %0 = ptrtoint ptr addrspace(1) %addr to i64
  %1 = lshr i64 %0, 9
  %2 = getelementptr inbounds i8, ptr inttoptr (i64 139709660639232 to ptr), i64 %1
  store atomic i8 0, ptr %2 unordered, align 1
  ret void
}

define private hotspotcc void @jeandle.pre_barrier(ptr addrspace(1) %addr) #0 {
entry:
  ret void
}

define private hotspotcc void @jeandle.post_barrier(ptr addrspace(1) %addr, ptr addrspace(1) captures(none) %oop) #0 {
entry:
  call void @jeandle.card_table_barrier(ptr addrspace(1) %addr)
  ret void
}

define hotspotcc void @test_gc_write_barrier(ptr addrspace(1) %dst, ptr addrspace(1) %src) gc "hotspotgc" {
entry:                                        ; preds = %entry
  %derived.pointer = getelementptr inbounds i8, ptr addrspace(1) %dst, i64 24
  store atomic ptr addrspace(1) %src, ptr addrspace(1) %derived.pointer unordered, align 8
  ret void

}

attributes #0 = { noinline "lower-phase"="1" }

!java-method-compilation = !{}
