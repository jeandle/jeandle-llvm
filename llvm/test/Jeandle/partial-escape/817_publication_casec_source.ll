; RUN: opt -S -verify-each -passes='require<partial-escape-analysis>,partial-escape-transform' %s | FileCheck %s
; RUN: opt -S -verify-each -passes='partial-escape-iterative' -jeandle-pea-iterations=8 %s | FileCheck %s
;
; Publication on a source identity in an as-yet unvisited loop exit does not
; observe that identity. It must not prevent the loop's virtual Case-C merge.
; CHECK-LABEL: define i32 @casec_source_publication(
; CHECK-NOT: call
; CHECK-NOT: store
; CHECK-NOT: load
; CHECK: %[[VALUE:[^ ]+]] = phi i32 [ 7, %entry ], [ 13, %body ]
; CHECK-NOT: call
; CHECK-NOT: store
; CHECK-NOT: load
; CHECK: ret i32 %[[VALUE]]
target datalayout = "e-p:64:64"
declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1) nounwind
declare hotspotcc void @jeandle.publish_writes(ptr addrspace(1)) nounwind "gc-leaf-function"
define i32 @casec_source_publication(i32 %limit) gc "hotspotgc" {
entry:
  %a = call hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 23456 to ptr), i32 24, i1 false)
  %af = getelementptr inbounds i8, ptr addrspace(1) %a, i64 16
  store atomic i32 7, ptr addrspace(1) %af unordered, align 4
  br label %loop
loop:
  %p = phi ptr addrspace(1) [ %a, %entry ], [ %b, %body ]
  %i = phi i32 [ 0, %entry ], [ %next, %body ]
  %field = getelementptr inbounds i8, ptr addrspace(1) %p, i64 16
  %value = load atomic i32, ptr addrspace(1) %field unordered, align 4
  %again = icmp ult i32 %i, %limit
  br i1 %again, label %body, label %exit
body:
  %b = call hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 23456 to ptr), i32 24, i1 false)
  %bf = getelementptr inbounds i8, ptr addrspace(1) %b, i64 16
  store atomic i32 13, ptr addrspace(1) %bf unordered, align 4
  %next = add nuw i32 %i, 1
  br label %loop
exit:
  call hotspotcc void @jeandle.publish_writes(ptr addrspace(1) %a)
  ret i32 %value
}
!java-method-compilation = !{}
