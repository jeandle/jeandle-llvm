; RUN: opt -S -passes="type-check-elimination" -jeandle-vm-callback-log=%S/Inputs/instanceof-interfaces.cblog %s 2>&1 | FileCheck %s

; Test: object with interface 2 and interface 3(IsSubtype(2, 3) = IsSubtype(3, 2) => false), then check interface 2 again.
;  IsSubtype({2, 3}, 2) => true, so the check folds to true.

declare i1 @jeandle.check_instanceof(ptr addrspace(0), ptr addrspace(1) nonnull)
define hotspotcc i32 @test(ptr addrspace(1) nonnull "java-klass"="1" %0) gc "hotspotgc" {
entry:
  %OrigPcSlot = alloca i64, align 8
  br label %check_subtype.i0

check_subtype.i0:                                            ; preds = %entry
  %1 = call i1 @jeandle.check_instanceof(ptr inttoptr (i64 2 to ptr), ptr addrspace(1) %0)
  br i1 %1, label %check_subtype.i1, label %bci_2

check_subtype.i1:                                            ; preds = %check_subtype.i0
  %3 = call i1 @jeandle.check_instanceof(ptr inttoptr (i64 3 to ptr), ptr addrspace(1) %0)
  br i1 %3, label %check_subtype.i2, label %bci_2

check_subtype.i2:                                           ; preds = %check_subtype.i1
  %5 = call i1 @jeandle.check_instanceof(ptr inttoptr (i64 2 to ptr), ptr addrspace(1) %0)
  br i1 %5, label %bci_1, label %bci_2

bci_1:                                           ; preds = %check_subtype.i2
  ret i32 1

bci_2:                                           ; preds = %check_subtype.i2, %check_subtype.i1, %check_subtype.i0
  ret i32 0
}

; CHECK: check_subtype.i2:                                 ; preds = %check_subtype.i1
; CHECK:   br i1 true, label %bci_1, label %bci_2

!java-method-compilation = !{}