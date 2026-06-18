; RUN: opt -S -passes="constant-field-folding" -jeandle-vm-callback-log=%S/Inputs/field-strip-invariant-group.cblog %s 2>&1 | FileCheck %s

; Symmetric to field-launder-in-phi: verifies llvm.strip.invariant.group is
; also recognised as a lattice forwarder and stripped by matchFieldLoad.

@oop_handle_Test_0 = external global ptr addrspace(1)

declare ptr addrspace(1) @llvm.strip.invariant.group.p1(ptr addrspace(1))

define i32 @test(i1 %c) gc "hotspotgc" {
entry:
  %src = load ptr addrspace(1), ptr @oop_handle_Test_0
  %stripped = call ptr addrspace(1) @llvm.strip.invariant.group.p1(ptr addrspace(1) %src)
  br i1 %c, label %A, label %B
A:
  br label %merge
B:
  br label %merge
merge:
  %merged = phi ptr addrspace(1) [ %src, %A ], [ %stripped, %B ]
  %addr = getelementptr i8, ptr addrspace(1) %merged, i64 12
  %value = load i32, ptr addrspace(1) %addr
  ret i32 %value
}

; CHECK: ret i32 42

!java-method-compilation = !{}
