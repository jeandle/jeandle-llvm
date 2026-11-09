; RUN: opt -S -verify-each -passes='java-operation-lower<phase=0>' %s | FileCheck %s --check-prefix=KEPT
; RUN: opt -S -verify-each -passes='java-operation-lower<phase=1>,java-operation-lower<phase=1>' %s | FileCheck %s --check-prefix=PLATFORM
; RUN: sed 's/@jeandle.membar_storestore/@unused_storestore/g' %s | opt -S -verify-each -passes='java-operation-lower<phase=1>,java-operation-lower<phase=1>' | FileCheck %s --check-prefix=FALLBACK
;
; Publication lowers once, at phase 1, whether or not PEA ran. Prefer the
; runtime's target StoreStore implementation; standalone modules use release.
target datalayout = "e-p:64:64"
declare hotspotcc void @jeandle.publish_writes(ptr addrspace(1)) nounwind "gc-leaf-function"
declare void @llvm.aarch64.dmb(i32)
define private hotspotcc void @jeandle.membar_storestore() "lower-phase"="1" {
  call void @llvm.aarch64.dmb(i32 10)
  ret void
}

; KEPT-LABEL: define ptr addrspace(1) @publish(
; KEPT: store atomic i32 %value, {{.*}} unordered, align 4
; KEPT-NEXT: call hotspotcc void @jeandle.publish_writes(ptr addrspace(1) %receiver)
; KEPT-NEXT: ret ptr addrspace(1) %receiver
; PLATFORM-LABEL: define ptr addrspace(1) @publish(
; PLATFORM: store atomic i32 %value, {{.*}} unordered, align 4
; PLATFORM-NEXT: call void @llvm.aarch64.dmb(i32 10)
; PLATFORM-NEXT: ret ptr addrspace(1) %receiver
; FALLBACK-LABEL: define ptr addrspace(1) @publish(
; FALLBACK: store atomic i32 %value, {{.*}} unordered, align 4
; FALLBACK-NEXT: fence release
; FALLBACK-NEXT: ret ptr addrspace(1) %receiver
define ptr addrspace(1) @publish(ptr addrspace(1) %receiver, i32 %value) {
  %field = getelementptr inbounds i8, ptr addrspace(1) %receiver, i64 16
  store atomic i32 %value, ptr addrspace(1) %field unordered, align 4
  call hotspotcc void @jeandle.publish_writes(ptr addrspace(1) %receiver)
  ret ptr addrspace(1) %receiver
}
