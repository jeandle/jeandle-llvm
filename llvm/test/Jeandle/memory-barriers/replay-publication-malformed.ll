; RUN: split-file %s %t
; RUN: not env LLVM_DISABLE_SYMBOLIZATION=1 opt -disable-output -passes='java-operation-lower<phase=1>' %t/count.ll 2>&1 | FileCheck %s
; RUN: not env LLVM_DISABLE_SYMBOLIZATION=1 opt -disable-output -passes='java-operation-lower<phase=1>' %t/zero.ll 2>&1 | FileCheck %s
; RUN: not env LLVM_DISABLE_SYMBOLIZATION=1 opt -disable-output -passes='java-operation-lower<phase=1>' %t/mask.ll 2>&1 | FileCheck %s
; RUN: not env LLVM_DISABLE_SYMBOLIZATION=1 opt -disable-output -passes='java-operation-lower<phase=1>' %t/empty-mask.ll 2>&1 | FileCheck %s
; RUN: not env LLVM_DISABLE_SYMBOLIZATION=1 opt -disable-output -passes='java-operation-lower<phase=1>' %t/owner-type.ll 2>&1 | FileCheck %s
; RUN: not env LLVM_DISABLE_SYMBOLIZATION=1 opt -disable-output -passes='java-operation-lower<phase=1>' %t/dynamic.ll 2>&1 | FileCheck %s
; RUN: not env LLVM_DISABLE_SYMBOLIZATION=1 opt -disable-output -passes='java-operation-lower<phase=1>' %t/wide-mask.ll 2>&1 | FileCheck %s
; RUN: not env LLVM_DISABLE_SYMBOLIZATION=1 opt -disable-output -passes='java-operation-lower<phase=1>' %t/bundle.ll 2>&1 | FileCheck %s
; RUN: not env LLVM_DISABLE_SYMBOLIZATION=1 opt -disable-output -passes='java-operation-lower<phase=1>' %t/cc.ll 2>&1 | FileCheck %s
; RUN: not env LLVM_DISABLE_SYMBOLIZATION=1 opt -disable-output -passes='java-operation-lower<phase=1>' %t/fixed.ll 2>&1 | FileCheck %s
; RUN: not env LLVM_DISABLE_SYMBOLIZATION=1 opt -disable-output -passes='java-operation-lower<phase=1>' %t/declcc.ll 2>&1 | FileCheck %s
; RUN: not env LLVM_DISABLE_SYMBOLIZATION=1 opt -disable-output -passes='java-operation-lower<phase=1>' %t/invoke.ll 2>&1 | FileCheck %s
; RUN: not env LLVM_DISABLE_SYMBOLIZATION=1 opt -disable-output -passes='java-operation-lower<phase=1>' %t/return.ll 2>&1 | FileCheck %s
; CHECK: invalid Jeandle memory barrier call

;--- count.ll
declare hotspotcc void @jeandle.membar_replay_publish(i32, ...)
define void @bad(ptr addrspace(1) %p, i32 %n) {
  call hotspotcc void (i32, ...) @jeandle.membar_replay_publish(i32 2, ptr addrspace(1) %p, i32 1)
  ret void
}

;--- zero.ll
declare hotspotcc void @jeandle.membar_replay_publish(i32, ...)
define void @bad(ptr addrspace(1) %p, i32 %n) {
  call hotspotcc void (i32, ...) @jeandle.membar_replay_publish(i32 0)
  ret void
}

;--- mask.ll
declare hotspotcc void @jeandle.membar_replay_publish(i32, ...)
define void @bad(ptr addrspace(1) %p, i32 %n) {
  call hotspotcc void (i32, ...) @jeandle.membar_replay_publish(i32 1, ptr addrspace(1) %p, i32 4)
  ret void
}

;--- empty-mask.ll
declare hotspotcc void @jeandle.membar_replay_publish(i32, ...)
define void @bad(ptr addrspace(1) %p, i32 %n) {
  call hotspotcc void (i32, ...) @jeandle.membar_replay_publish(i32 1, ptr addrspace(1) %p, i32 0)
  ret void
}

;--- owner-type.ll
declare hotspotcc void @jeandle.membar_replay_publish(i32, ...)
define void @bad(ptr addrspace(1) %p, i32 %n) {
  call hotspotcc void (i32, ...) @jeandle.membar_replay_publish(i32 1, ptr null, i32 1)
  ret void
}

;--- dynamic.ll
declare hotspotcc void @jeandle.membar_replay_publish(i32, ...)
define void @bad(ptr addrspace(1) %p, i32 %n) {
  call hotspotcc void (i32, ...) @jeandle.membar_replay_publish(i32 %n, ptr addrspace(1) %p, i32 1)
  ret void
}

;--- wide-mask.ll
declare hotspotcc void @jeandle.membar_replay_publish(i32, ...)
define void @bad(ptr addrspace(1) %p, i32 %n) {
  call hotspotcc void (i32, ...) @jeandle.membar_replay_publish(i32 1, ptr addrspace(1) %p, i64 1)
  ret void
}

;--- bundle.ll
declare hotspotcc void @jeandle.membar_replay_publish(i32, ...)
define void @bad(ptr addrspace(1) %p, i32 %n) {
  call hotspotcc void (i32, ...) @jeandle.membar_replay_publish(i32 1, ptr addrspace(1) %p, i32 1) [ "deopt"() ]
  ret void
}

;--- cc.ll
declare void @jeandle.membar_replay_publish(i32, ...)
define void @bad(ptr addrspace(1) %p, i32 %n) {
  call void (i32, ...) @jeandle.membar_replay_publish(i32 1, ptr addrspace(1) %p, i32 1)
  ret void
}

;--- fixed.ll
declare hotspotcc void @jeandle.membar_replay_publish(i32, ptr addrspace(1), i32)
define void @bad(ptr addrspace(1) %p, i32 %n) {
  call hotspotcc void @jeandle.membar_replay_publish(i32 1, ptr addrspace(1) %p, i32 1)
  ret void
}

;--- declcc.ll
declare void @jeandle.membar_replay_publish(i32, ...)
define void @bad(ptr addrspace(1) %p) {
  call hotspotcc void (i32, ...) @jeandle.membar_replay_publish(i32 1, ptr addrspace(1) %p, i32 1)
  ret void
}

;--- invoke.ll
declare hotspotcc void @jeandle.membar_replay_publish(i32, ...)
declare i32 @personality(...)
define void @bad(ptr addrspace(1) %p) personality ptr @personality {
  invoke hotspotcc void (i32, ...) @jeandle.membar_replay_publish(i32 1, ptr addrspace(1) %p, i32 1) to label %done unwind label %unwind
done:
  ret void
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

;--- return.ll
declare hotspotcc i32 @jeandle.membar_replay_publish(i32, ...)
define void @bad(ptr addrspace(1) %p) {
  %v = call hotspotcc i32 (i32, ...) @jeandle.membar_replay_publish(i32 1, ptr addrspace(1) %p, i32 1)
  ret void
}
