; RUN: opt -S -passes="recover-type-info" -jeandle-vm-callback-log=%S/Inputs/recover-array-element-context-sharpened.cblog %s 2>&1 | FileCheck %s

; Context-sensitive recovery: the array argument is statically typed as
; Object[] (klass 20), but a dominating jeandle.check_instanceof proves it is
; String[] (klass 22) on the true-edge that dominates the aaload. The element
; metadata must use the sharpened element klass 23, not the declared element
; klass of Object[] — this is the capability the frontend's context-insensitive
; getJavaType query could not provide.

declare i1 @jeandle.check_instanceof(ptr addrspace(0), ptr addrspace(1) nonnull)

define void @test(ptr addrspace(1) "java-klass"="20" %arr, i64 %idx) #0 gc "hotspotgc" {
entry:
  %check = call i1 @jeandle.check_instanceof(ptr addrspace(0) inttoptr (i64 22 to ptr addrspace(0)), ptr addrspace(1) nonnull %arr)
  br i1 %check, label %pass, label %fail

pass:
  %base = getelementptr i8, ptr addrspace(1) %arr, i64 16
  %elem_addr = getelementptr ptr addrspace(1), ptr addrspace(1) %base, i64 %idx
  %elem = load ptr addrspace(1), ptr addrspace(1) %elem_addr
  ret void

fail:
  ret void
}

; CHECK: %elem = load ptr addrspace(1), ptr addrspace(1) %elem_addr{{.*}}, !java-klass ![[K:[0-9]+]]
; CHECK: ![[K]] = !{i64 23}

attributes #0 = { "java-method"="0" }

!java-method-compilation = !{}
