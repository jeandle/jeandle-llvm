; RUN: opt -S -passes='java-operation-lower<phase=0>' %s 2>&1 | FileCheck %s

; CHECK-NOT: %1 = call i32 @jeandle.instanceof(i32 7, ptr addrspace(1) %0)
; CHECK-NOT: define i32 @jeandle.instanceof
; CHECK-NOT: %1 = call i32 @jeandle.test1(i32 %super_kid, ptr addrspace(1) nocapture %oop)
; CHECK-NOT: define i32 @jeandle.test1
; CHECK:     define i32 @jeandle.test2
; CHECK-NOT: "lower-phase"="0"
; CHECK:     "lower-phase"="1"
define hotspotcc i32 @"TestInstanceof_test_(LTestInstanceof$Animal;)Z"(ptr addrspace(1) %0) #0 gc "hotspotgc" {
entry:
  br label %bci_0

bci_0:                                            ; preds = %entry
  %1 = call i32 @jeandle.instanceof(i32 7, ptr addrspace(1) %0)
  ret i32 %1
}

define i32 @jeandle.instanceof(i32 %super_kid, ptr addrspace(1) nocapture %oop) #1 {
  %1 = call i32 @jeandle.test1(i32 %super_kid, ptr addrspace(1) nocapture %oop)
  ret i32 %1
}

define i32 @jeandle.test1(i32 %super_kid, ptr addrspace(1) nocapture %oop) #1 {
  ret i32 1
}

define i32 @jeandle.test2(i32 %super_kid, ptr addrspace(1) nocapture %oop) #2 {
  ret i32 1
}

attributes #0 = { "use-compressed-oops" }
attributes #1 = { "lower-phase"="0" }
attributes #2 = { "lower-phase"="1" }
