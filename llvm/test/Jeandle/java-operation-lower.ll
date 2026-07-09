; RUN: opt -S -passes="java-operation-lower<phase=0>" %s 2>&1 | FileCheck %s

; CHECK-NOT: call i32 @test0(i32 7, ptr addrspace(1) %0)
; CHECK-NOT: define i32 @test0
; CHECK-NOT: define i32 @test1
; CHECK-NOT: define i32 @test4
; CHECK-NOT: define i32 @test5
; CHECK-NOT: "lower-phase"="0"

;CHECK: define hotspotcc i32 @root(ptr addrspace(1) %0) #0 gc "hotspotgc" {
;CHECK: entry:
;CHECK:   br label %bci_0
;CHECK: bci_0:                                            ; preds = %entry
;CHECK:   br label %bci_1
;CHECK: bci_1:                                            ; preds = %bci_0
;CHECK:   %1 = call i32 @test3(i32 7, ptr addrspace(1) %0)
;CHECK:   br label %bci_2
;CHECK: bci_2:                                            ; preds = %bci_1
;CHECK:   br label %bci_3
;CHECK: bci_3:                                            ; preds = %bci_2
;CHECK:   %2 = call i32 @test2(i32 7, ptr addrspace(1) %0)
;CHECK:   ret i32 1
;CHECK: }
;CHECK: define i32 @test3(i32 %super_kid, ptr addrspace(1) captures(none) %oop) #1 {
;CHECK: entry:
;CHECK:   br label %bci_0
;CHECK: bci_0:                                            ; preds = %entry
;CHECK:   ret i32 1
;CHECK: }
;CHECK: define i32 @test2(i32 %super_kid, ptr addrspace(1) captures(none) %oop) #1 {
;CHECK:   ret i32 1
;CHECK: }
;CHECK: attributes #0 = { "noinline" "use-compressed-oops" }
;CHECK: attributes #1 = { "lower-phase"="1" "noinline" }

; from:
;                                    root
;                                     |
;       +-----------+-----------------+-----------------+
;       |           |                 |                 |
; test0(phase0)  test3(phase1)  test4(phase0)  test5(phase0)
;                   |                 |                 |
;                   |                 |                 |
;                test1(phase0)  test1(phase0)  test2(phase1)
; to:
;                                    root
;                                     |
;       +-----------+-----------------+-----------------+
;       |           |                 |                 |
;    inined  test3(phase1)         inlined           inlined
;                   |                 |                 |
;                   |                 |                 |
;                inlined           inlined         test2(phase1)
define hotspotcc i32 @root(ptr addrspace(1) %0) #0 gc "hotspotgc" {
entry:
  br label %bci_0

bci_0:                                            ; preds = %entry
  %1 = call i32 @test0(i32 7, ptr addrspace(1) %0)
  br label %bci_1

bci_1:
  %2 = call i32 @test3(i32 7, ptr addrspace(1) %0)
  br label %bci_2

bci_2:
  %3 = call i32 @test4(i32 7, ptr addrspace(1) %0)
  br label %bci_3

bci_3:
  %4 = call i32 @test5(i32 7, ptr addrspace(1) %0)

  ret i32 %4
}

define i32 @test3(i32 %super_kid, ptr addrspace(1) captures(none) %oop) #2 {
entry:
  br label %bci_0

bci_0:                                            ; preds = %entry
  %1 = call i32 @test1(i32 7, ptr addrspace(1) %oop)
  ret i32 1
}

define i32 @test4(i32 %super_kid, ptr addrspace(1) captures(none) %oop) #1 {
entry:
  br label %bci_0

bci_0:                                            ; preds = %entry
  %1 = call i32 @test1(i32 7, ptr addrspace(1) %oop)
  ret i32 1
}

define i32 @test5(i32 %super_kid, ptr addrspace(1) captures(none) %oop) #1 {
entry:
  br label %bci_0

bci_0:                                            ; preds = %entry
  %1 = call i32 @test2(i32 7, ptr addrspace(1) %oop)
  ret i32 1
}

define i32 @test0(i32 %super_kid, ptr addrspace(1) captures(none) %oop) #1 {
  ret i32 1
}

define i32 @test1(i32 %super_kid, ptr addrspace(1) captures(none) %oop) #1 {
  ret i32 1
}

define i32 @test2(i32 %super_kid, ptr addrspace(1) captures(none) %oop) #2 {
  ret i32 1
}

attributes #0 = { "use-compressed-oops" "noinline"}
attributes #1 = { "lower-phase"="0" "noinline"}
attributes #2 = { "lower-phase"="1" "noinline"}
