; RUN: opt -S -passes=recover-type-info -jeandle-vm-callback-log=%S/Inputs/recover-invariant-group-select.cblog %s | FileCheck %s
declare ptr addrspace(1) @llvm.launder.invariant.group.p1(ptr addrspace(1))
declare ptr addrspace(1) @llvm.strip.invariant.group.p1(ptr addrspace(1))
define void @test(ptr addrspace(1) noundef "java-klass"="5" %obj, i1 %pick) #0 gc "hotspotgc" {
  %a = call ptr addrspace(1) @llvm.launder.invariant.group.p1(ptr addrspace(1) %obj)
  %b = call ptr addrspace(1) @llvm.strip.invariant.group.p1(ptr addrspace(1) %obj)
  %selected = select i1 %pick, ptr addrspace(1) %a, ptr addrspace(1) %b
  %addr = getelementptr i8, ptr addrspace(1) %selected, i64 16
  %field = load ptr addrspace(1), ptr addrspace(1) %addr
  ret void
}
; CHECK: %field = load ptr addrspace(1), ptr addrspace(1) %addr{{.*}}, !java-klass ![[K:[0-9]+]]
; CHECK: ![[K]] = !{i64 7}
attributes #0 = { "java-method"="0" }
!java-method-compilation = !{}
