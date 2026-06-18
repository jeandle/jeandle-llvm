; RUN: opt -S -passes="constant-field-folding" -jeandle-vm-callback-log=%S/Inputs/field-object-chain-3.cblog %s 2>&1 | FileCheck %s

; Three-level oop chain, similar to the testObjectChain jtreg test.
; Uses atomic-unordered loads (Java load semantics).

@oop_handle_java.lang.Class_0 = external global ptr addrspace(1)

define i32 @test() gc "hotspotgc" {
entry:
  %0 = load ptr addrspace(1), ptr @oop_handle_java.lang.Class_0
  %1 = getelementptr inbounds i8, ptr addrspace(1) %0, i64 208
  %2 = load atomic ptr addrspace(1), ptr addrspace(1) %1 unordered, align 8
  %3 = getelementptr inbounds i8, ptr addrspace(1) %2, i64 16
  %4 = load atomic ptr addrspace(1), ptr addrspace(1) %3 unordered, align 8
  %5 = getelementptr inbounds i8, ptr addrspace(1) %4, i64 16
  %6 = load atomic i32, ptr addrspace(1) %5 unordered, align 4
  ret i32 %6
}

; CHECK: @oop_handle_Child_1 = external dso_local global ptr addrspace(1)
; CHECK: @oop_handle_Grandchild_2 = external dso_local global ptr addrspace(1)
; CHECK: ret i32 77

!java-method-compilation = !{}
