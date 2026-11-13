; RUN: opt -S -verify-each -passes='require<partial-escape-analysis>,partial-escape-transform' %s | FileCheck %s
; Barrier-only predecessor replay must be confined to the escaping edge.
target datalayout = "e-p:64:64"
declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare hotspotcc void @jeandle.membar_constructor_freeze(ptr addrspace(1))
declare void @sink(ptr addrspace(1))

; CHECK-LABEL: define void @barrier_edge(
; CHECK: left:
; CHECK-NEXT: br i1 %early, label %exit, label %[[EDGE:[a-zA-Z0-9.]+]]
; CHECK: [[EDGE]]:
; CHECK-NEXT: call hotspotcc void @jeandle.membar_constructor_freeze(ptr addrspace(1) %object)
; CHECK-NEXT: br label %join
; CHECK: join:
; CHECK-NEXT: %p = phi ptr addrspace(1) [ null, %right ], [ %object, %[[EDGE]] ]
; CHECK-NEXT: call void @sink(ptr addrspace(1) %p)
; CHECK: exit:
; CHECK-NEXT: ret void
define void @barrier_edge(i1 %choose, i1 %early) gc "hotspotgc" {
entry:
  %object = call hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 23456 to ptr), i32 24, i1 false)
  call hotspotcc void @jeandle.membar_constructor_freeze(ptr addrspace(1) %object)
  br i1 %choose, label %left, label %right
left:
  br i1 %early, label %exit, label %join
right:
  br label %join
join:
  %p = phi ptr addrspace(1) [ %object, %left ], [ null, %right ]
  call void @sink(ptr addrspace(1) %p)
  ret void
exit:
  ret void
}
!java-method-compilation = !{}
