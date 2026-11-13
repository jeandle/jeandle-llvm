; RUN: opt -S -verify-each -passes='java-operation-lower<phase=0>' %s | FileCheck %s --check-prefix=KEEP
; RUN: opt -S -verify-each -mtriple=x86_64-unknown-linux-gnu -passes='java-operation-lower<phase=1>' %s | FileCheck %s --check-prefixes=LOWER,X86
; RUN: opt -S -verify-each -mtriple=aarch64-unknown-linux-gnu -passes='java-operation-lower<phase=1>,default<O3>' %s | FileCheck %s --check-prefixes=LOWER,ARM
; RUN: opt -S -verify-each -mtriple=riscv64-unknown-linux-gnu -passes='java-operation-lower<phase=1>' %s | FileCheck %s --check-prefixes=LOWER,X86
;
; Every owner has its own obligation, discharged together in phase 1.
declare hotspotcc void @jeandle.membar_replay_publish(i32, ...)
; KEEP-LABEL: define void @publish(
; KEEP-NEXT: call hotspotcc void (i32, ...) @jeandle.membar_replay_publish
; LOWER-LABEL: define void @publish(
; X86-NEXT: fence release
; ARM-NEXT: {{.*}}call void @llvm.aarch64.dmb(i32 10)
; LOWER-NEXT: ret void
define void @publish(ptr addrspace(1) %a, ptr addrspace(1) %b) {
  call hotspotcc void (i32, ...) @jeandle.membar_replay_publish(i32 2, ptr addrspace(1) %a, i32 1, ptr addrspace(1) %b, i32 2)
  ret void
}
