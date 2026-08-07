; RUN: opt -S -passes="recover-type-info" -jeandle-vm-callback-log=%S/Inputs/recover-select-merge.cblog %s 2>&1 | FileCheck %s

; Two bases of different declared klasses (5 and 6) are merged with a select,
; producing LCA(7, 8) = 10. A further field load off the merged value resolves
; via GetFieldType(10, 24) = 11. Exercises select meet (LCA) plus a downstream
; field load whose base is a forwarder (the select).

define void @test(ptr addrspace(1) "java-klass"="5" %a,
                  ptr addrspace(1) "java-klass"="6" %b,
                  i1 %cond) #0 gc "hotspotgc" {
entry:
  %a.addr = getelementptr i8, ptr addrspace(1) %a, i64 16
  %fa = load ptr addrspace(1), ptr addrspace(1) %a.addr
  %b.addr = getelementptr i8, ptr addrspace(1) %b, i64 16
  %fb = load ptr addrspace(1), ptr addrspace(1) %b.addr
  %m = select i1 %cond, ptr addrspace(1) %fa, ptr addrspace(1) %fb
  %m.addr = getelementptr i8, ptr addrspace(1) %m, i64 24
  %fc = load ptr addrspace(1), ptr addrspace(1) %m.addr
  ret void
}

; CHECK: %fa = load ptr addrspace(1), ptr addrspace(1) %a.addr{{.*}}, !java-klass ![[FA:[0-9]+]]
; CHECK: %fb = load ptr addrspace(1), ptr addrspace(1) %b.addr{{.*}}, !java-klass ![[FB:[0-9]+]]
; CHECK: %fc = load ptr addrspace(1), ptr addrspace(1) %m.addr{{.*}}, !java-klass ![[FC:[0-9]+]]
; CHECK: ![[FA]] = !{i64 7}
; CHECK: ![[FB]] = !{i64 8}
; CHECK: ![[FC]] = !{i64 11}

attributes #0 = { "java-method"="0" }

!java-method-compilation = !{}
