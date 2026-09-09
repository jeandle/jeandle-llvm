; RUN: opt -S -passes="recover-type-info" -jeandle-vm-callback-log=%S/Inputs/recover-array-element-exact.cblog %s 2>&1 | FileCheck %s

; Same as recover-array-element.ll, but the element klass is effectively final,
; so the recovered metadata must carry !java-klass-exact as well.

define void @test(ptr addrspace(1) "java-klass"="20" %arr, i64 %idx) #0 gc "hotspotgc" {
entry:
  %base = getelementptr i8, ptr addrspace(1) %arr, i64 16
  %elem_addr = getelementptr ptr addrspace(1), ptr addrspace(1) %base, i64 %idx
  %elem = load ptr addrspace(1), ptr addrspace(1) %elem_addr
  ret void
}

; CHECK: %elem = load ptr addrspace(1), ptr addrspace(1) %elem_addr{{.*}}, !java-klass ![[K:[0-9]+]]{{.*}}, !java-klass-exact ![[E:[0-9]+]]
; CHECK: ![[K]] = !{i64 21}
; CHECK: ![[E]] = !{}

attributes #0 = { "java-method"="0" }

!java-method-compilation = !{}
