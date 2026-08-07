; RUN: opt -S -passes="recover-type-info" -jeandle-vm-callback-log=%S/Inputs/recover-loop-linked-list.cblog %s 2>&1 | FileCheck %s

; Classic linked-list traversal: a loop PHI carries an oop whose declared klass
; is Node (5); each iteration loads the .next field (also Node). The loop PHI
; %p is self-referential on the back-edge. The worklist must converge: %p and
; %next both resolve to klass 5 without infinite iteration.

define void @test(ptr addrspace(1) "java-klass"="5" %head, i1 %cond) #0 gc "hotspotgc" {
entry:
  br label %loop

loop:
  %p = phi ptr addrspace(1) [ %head, %entry ], [ %next, %loop ]
  %n.addr = getelementptr i8, ptr addrspace(1) %p, i64 16
  %next = load ptr addrspace(1), ptr addrspace(1) %n.addr
  br i1 %cond, label %loop, label %exit

exit:
  ret void
}

; CHECK: %next = load ptr addrspace(1), ptr addrspace(1) %n.addr{{.*}}, !java-klass ![[K:[0-9]+]]
; CHECK: ![[K]] = !{i64 5}

attributes #0 = { "java-method"="0" }

!java-method-compilation = !{}
