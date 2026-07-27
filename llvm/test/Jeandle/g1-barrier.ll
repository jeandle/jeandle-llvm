; RUN: opt -S -passes="java-operation-lower<phase=0>,insert-gc-barriers,java-operation-lower<phase=1>" %s 2>&1 | FileCheck %s

; CHECK: %derived.pointer = getelementptr inbounds i8, ptr addrspace(1) %dst, i64 24
; CHECK-NEXT: %0 = load atomic ptr addrspace(1), ptr addrspace(1) %derived.pointer unordered, align 8
; CHECK-NEXT: store ptr addrspace(1) %0, ptr @satb_log
; CHECK-NEXT: store atomic ptr addrspace(1) %src, ptr addrspace(1) %derived.pointer unordered, align 8
; CHECK-NEXT: %1 = ptrtoint ptr addrspace(1) %derived.pointer to i64
; CHECK-NEXT: %2 = lshr i64 %1, 9
; CHECK-NEXT: %3 = getelementptr inbounds i8, ptr inttoptr (i64 139709660639232 to ptr), i64 %2
; CHECK-NEXT: store atomic i8 0, ptr %3 unordered, align 1

@satb_log = private global ptr addrspace(1) null

define private hotspotcc void @jeandle.g1_pre_barrier(ptr addrspace(1) %addr) #0 {
entry:
  %0 = load atomic ptr addrspace(1), ptr addrspace(1) %addr unordered, align 8
  store ptr addrspace(1) %0, ptr @satb_log
  ret void
}

define private hotspotcc void @jeandle.g1_post_barrier(ptr addrspace(1) %addr, ptr addrspace(1) %val) #0 {
entry:
  %0 = ptrtoint ptr addrspace(1) %addr to i64
  %1 = lshr i64 %0, 9
  %2 = getelementptr inbounds i8, ptr inttoptr (i64 139709660639232 to ptr), i64 %1
  store atomic i8 0, ptr %2 unordered, align 1
  ret void
}

define private hotspotcc void @jeandle.pre_barrier(ptr addrspace(1) %addr) #0 {
entry:
  call void @jeandle.g1_pre_barrier(ptr addrspace(1) %addr)
  ret void
}

define private hotspotcc void @jeandle.post_barrier(ptr addrspace(1) %addr, ptr addrspace(1) captures(none) %oop) #0 {
entry:
  call void @jeandle.g1_post_barrier(ptr addrspace(1) %addr, ptr addrspace(1) %oop)
  ret void
}

define hotspotcc void @test_g1_barrier(ptr addrspace(1) %dst, ptr addrspace(1) %src) gc "hotspotgc" {
entry:
  %derived.pointer = getelementptr inbounds i8, ptr addrspace(1) %dst, i64 24
  store atomic ptr addrspace(1) %src, ptr addrspace(1) %derived.pointer unordered, align 8
  ret void
}

attributes #0 = { noinline "lower-phase"="1" }

!java-method-compilation = !{}
