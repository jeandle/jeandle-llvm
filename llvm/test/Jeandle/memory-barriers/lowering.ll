; RUN: opt -S -verify-each -passes='java-operation-lower<phase=0>' %s | FileCheck %s --check-prefix=KEEP
; RUN: opt -S -verify-each -mtriple=x86_64-unknown-linux-gnu -passes='java-operation-lower<phase=1>,java-operation-lower<phase=1>' %s | FileCheck %s --check-prefixes=LOWER,X86
; RUN: opt -S -verify-each -mtriple=aarch64-unknown-linux-gnu -passes='java-operation-lower<phase=1>,java-operation-lower<phase=1>' %s | FileCheck %s --check-prefixes=LOWER,ARM
; RUN: opt -S -verify-each -mtriple=riscv64-unknown-linux-gnu -passes='java-operation-lower<phase=1>,java-operation-lower<phase=1>' %s | FileCheck %s --check-prefixes=LOWER,X86
;
; Object ordering remains attributable until PEA ends. Target selection must
; work in modules without template definitions and be stable when repeated.
declare hotspotcc void @jeandle.membar_allocation_init(ptr addrspace(1))
declare hotspotcc void @jeandle.membar_constructor_freeze(ptr addrspace(1))
declare hotspotcc void @jeandle.membar_clone_source(ptr addrspace(1))
declare hotspotcc void @jeandle.membar_cpuorder()
declare hotspotcc void @jeandle.membar_acquire()
declare hotspotcc void @jeandle.membar_release()
declare hotspotcc void @jeandle.membar_full()

; KEEP-LABEL: define void @ordered(
; KEEP: call hotspotcc void @jeandle.membar_allocation_init
; KEEP: call hotspotcc void @jeandle.membar_constructor_freeze
; KEEP: call hotspotcc void @jeandle.membar_clone_source
; KEEP: call hotspotcc void @jeandle.membar_cpuorder
; LOWER-LABEL: define void @ordered(
; X86-NEXT: fence release
; X86-NEXT: fence release
; ARM-NEXT: call void @llvm.aarch64.dmb(i32 10)
; ARM-NEXT: call void @llvm.aarch64.dmb(i32 10)
; LOWER-NEXT: fence syncscope("singlethread") seq_cst
; LOWER-NEXT: fence syncscope("singlethread") seq_cst
; LOWER-NEXT: fence acquire
; LOWER-NEXT: fence release
; LOWER-NEXT: fence seq_cst
; LOWER-NEXT: ret void
define void @ordered(ptr addrspace(1) %p) {
  call hotspotcc void @jeandle.membar_allocation_init(ptr addrspace(1) %p)
  call hotspotcc void @jeandle.membar_constructor_freeze(ptr addrspace(1) null)
  call hotspotcc void @jeandle.membar_clone_source(ptr addrspace(1) %p)
  call hotspotcc void @jeandle.membar_cpuorder()
  call hotspotcc void @jeandle.membar_acquire()
  call hotspotcc void @jeandle.membar_release()
  call hotspotcc void @jeandle.membar_full()
  ret void
}
