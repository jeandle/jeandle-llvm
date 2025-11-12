; RUN: split-file %s %t
; RUN: opt -S --passes=-S -passes="insert-stack-probes" %t/enable.ll \
; RUN:   | FileCheck %s --check-prefix=CHECK-ENABLE
; RUN: opt -S --passes=-S -passes="insert-stack-probes" %t/unsupported.ll \
; RUN:   | FileCheck %s --check-prefix=CHECK-UNSUPPORTED

;--- enable.ll
target triple = "x86_64-unknown-linux-gnu"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"

define hotspotcc void @java_method() gc "hotspotgc" {
entry:
  ret void
}

define void @non_java() {
entry:
  ret void
}

!java_method_compilation = !{}

; CHECK-ENABLE: define hotspotcc void @java_method() #[[JAVA:[0-9]+]]
; CHECK-ENABLE: attributes #[[JAVA]] = { {{.*}}"probe-stack"="stubRoutines::throw_stack_overflow"
; CHECK-ENABLE-NOT: "probe-stack"

;--- unsupported.ll
target triple = "riscv64-unknown-linux-gnu"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"

define hotspotcc void @java_method() gc "hotspotgc" {
entry:
  ret void
}

!java_method_compilation = !{}

; CHECK-UNSUPPORTED-NOT: "probe-stack"
