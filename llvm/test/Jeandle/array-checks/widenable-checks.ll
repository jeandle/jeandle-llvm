; REQUIRES: x86-registered-target
; RUN: opt -passes='rewrite-statepoints-for-gc' -verify-each -S %s | FileCheck %s
; RUN: opt -passes='rewrite-statepoints-for-gc' -S %s | llc -mtriple=x86_64 -o /dev/null

; The trap request is a value, independently of the encoded frame state.
define hotspotcc i32 @dynamic_request(i1 %original, i1 %wide) gc "statepoint-example" {
; CHECK-LABEL: define hotspotcc i32 @dynamic_request(
; CHECK: %request = select i1 %original, i32 -154, i32 -12
; CHECK: call hotspotcc token {{.*}}@llvm.experimental.gc.statepoint{{.*}}@__llvm_deoptimize{{.*}}i32 %request{{.*}}[ "deopt"(i32 13) ]
entry:
  br i1 %wide, label %pass, label %fail
fail:
  %request = select i1 %original, i32 -154, i32 -12
  %r = call hotspotcc i32 (...) @llvm.experimental.deoptimize.i32(i32 %request) [ "deopt"(i32 13) ]
  ret i32 %r
pass:
  ret i32 42
}

declare i32 @llvm.experimental.deoptimize.i32(...)
