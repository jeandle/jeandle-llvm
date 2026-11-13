; RUN: opt -S -verify-each -passes='require<partial-escape-analysis>,partial-escape-transform' %s | FileCheck %s
; RUN: opt -S -verify-each -passes='require<partial-escape-analysis>,partial-escape-transform,require<partial-escape-analysis>,partial-escape-transform,require<partial-escape-analysis>,partial-escape-transform' %s | FileCheck %s
; RUN: opt -S -verify-each -mtriple=aarch64-unknown-linux-gnu -passes='function(require<partial-escape-analysis>,partial-escape-transform),java-operation-lower<phase=1>,default<O3>' %s | FileCheck %s --check-prefix=ARM
;
; Replay stores stay atomic. One publication covers both owners before escape.
target datalayout = "e-p:64:64"
declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(ptr addrspace(1), ptr addrspace(1))
; CHECK-LABEL: define void @two_objects(
; CHECK: store atomic i32 %x, {{.*}} unordered, align 4
; CHECK: store atomic i32 %y, {{.*}} unordered, align 4
; CHECK-NEXT: call hotspotcc void (i32, ...) @jeandle.membar_replay_publish(i32 2, ptr addrspace(1){{[^,%]*}} %a, i32 1, ptr addrspace(1){{[^,%]*}} %b, i32 1)
; CHECK-NEXT: call void @sink
; CHECK-NEXT: ret void
; ARM-LABEL: define void @two_objects(
; ARM-NOT: @llvm.aarch64.dmb
; ARM: store atomic i32 %x,
; ARM-NOT: @llvm.aarch64.dmb
; ARM: store atomic i32 %y,
; ARM-NEXT: call void @llvm.aarch64.dmb(i32 10)
; ARM-NEXT: call void @sink
; ARM-NEXT: ret void
define void @two_objects(i32 %x, i32 %y) gc "hotspotgc" {
entry:
  %a = call hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 23456 to ptr), i32 24, i1 false)
  %b = call hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 23456 to ptr), i32 24, i1 false)
  %af = getelementptr inbounds i8, ptr addrspace(1) %a, i64 16
  store atomic i32 %x, ptr addrspace(1) %af unordered, align 4
  %bf = getelementptr inbounds i8, ptr addrspace(1) %b, i64 16
  store atomic i32 %y, ptr addrspace(1) %bf unordered, align 4
  call void @sink(ptr addrspace(1) %a, ptr addrspace(1) %b)
  ret void
}
!java-method-compilation = !{}
