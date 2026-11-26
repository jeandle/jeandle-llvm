; RUN: opt -S -passes='require<partial-escape-analysis>,partial-escape-transform' -jeandle-vm-callback-log=%S/../string-intrinsics/Inputs/layout.cblog -verify-each %s | FileCheck %s --check-prefixes=CHECK,TRANSFORM
; RUN: opt -S -passes=partial-escape-iterative -jeandle-vm-callback-log=%S/../string-intrinsics/Inputs/layout.cblog -verify-each %s | FileCheck %s --check-prefixes=CHECK,ITERATIVE
;
; The first snapshot belongs to a folded-away arraylength operation. The
; later deopt bundles need their own widening at surviving program points,
; including sibling blocks that do not dominate one another.
target datalayout = "e-p:64:64-p1:64:64"
declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32, i1, i1)
declare hotspotcc i32 @jeandle.arraylength(ptr addrspace(1))
declare void @sink()
declare i32 @personality(...)

; CHECK-LABEL: @deleted_first_snapshot(
; CHECK-NOT: @jeandle.new_array
; ITERATIVE: common.ret:
; ITERATIVE-NEXT: ret i32 2
; CHECK: left:
; CHECK: %[[W:.*]] = zext i8 %value to i32
; CHECK-NOT: zext
; CHECK-NOT: call hotspotcc i32 @jeandle.arraylength
; CHECK: call void @sink()
; CHECK-SAME: i32 %[[W]]
; CHECK-SAME: i32 %[[W]]
; TRANSFORM: ret i32 2
; CHECK: right:
; CHECK: %[[R:.*]] = zext i8 %value to i32
; CHECK-NOT: zext
; CHECK: call void @sink()
; CHECK-SAME: i32 %[[R]]
; CHECK-SAME: i32 %[[R]]
; TRANSFORM: ret i32 2

define i32 @deleted_first_snapshot(i8 %value, i1 %choose) gc "hotspotgc" personality ptr @personality {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 2, i32 24, i32 16, i32 100, i1 false, i1 false) to label %body unwind label %u
body:
  %p = getelementptr i8, ptr addrspace(1) %o, i64 16
  %q = getelementptr i8, ptr addrspace(1) %o, i64 17
  store atomic i8 %value, ptr addrspace(1) %p unordered, align 1
  store atomic i8 %value, ptr addrspace(1) %q unordered, align 1
  %len = call hotspotcc i32 @jeandle.arraylength(ptr addrspace(1) %o) [ "deopt"(i32 99, i32 99, i64 12, ptr addrspace(1) %o) ]
  br i1 %choose, label %left, label %right
left:
  call void @sink() [ "deopt"(i32 100, i32 100, i64 12, ptr addrspace(1) %o) ]
  ret i32 %len
right:
  call void @sink() [ "deopt"(i32 101, i32 101, i64 12, ptr addrspace(1) %o) ]
  ret i32 %len
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}
!java-method-compilation = !{}
