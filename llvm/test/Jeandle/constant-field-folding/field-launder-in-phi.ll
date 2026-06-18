; RUN: opt -S -passes="constant-field-folding" -jeandle-vm-callback-log=%S/Inputs/field-launder-in-phi.cblog %s 2>&1 | FileCheck %s

; llvm.launder.invariant.group must be recognised as a lattice forwarder so
; that a ConstOop flows through it even when joined with a PHI. Both PHI
; operands derive from the same source (one directly, one via launder),
; so the merged value is Constant{0} and the field load folds.

@oop_handle_Test_0 = external global ptr addrspace(1)

declare ptr addrspace(1) @llvm.launder.invariant.group.p1(ptr addrspace(1))

define i32 @test(i1 %c) gc "hotspotgc" {
entry:
  %src = load ptr addrspace(1), ptr @oop_handle_Test_0
  %laundered = call ptr addrspace(1) @llvm.launder.invariant.group.p1(ptr addrspace(1) %src)
  br i1 %c, label %A, label %B
A:
  br label %merge
B:
  br label %merge
merge:
  %merged = phi ptr addrspace(1) [ %src, %A ], [ %laundered, %B ]
  %addr = getelementptr i8, ptr addrspace(1) %merged, i64 12
  %value = load i32, ptr addrspace(1) %addr
  ret i32 %value
}

; CHECK: ret i32 42

!java-method-compilation = !{}
