; RUN: opt -S -passes="recover-type-info" -jeandle-vm-callback-log=%S/Inputs/recover-loop-latch-sharpened.cblog %s 2>&1 | FileCheck %s

; Loop-latch edge sharpening: the back-edge of this single-block loop is the
; true successor of a check_instanceof proving %next is klass 7 (Node), so the
; loop-carried %p is meet(30 SubNode, 7-on-edge) = 7 rather than widening to 9
; (Object) through the declared type of next@16. With %p resolved to 7, the
; second field load at offset 24 (Node.data, klass 8) becomes recoverable.

declare i1 @jeandle.check_instanceof(ptr addrspace(0), ptr addrspace(1) nonnull)

define void @test(ptr addrspace(1) "java-klass"="30" %head) #0 gc "hotspotgc" {
entry:
  br label %loop

loop:
  %p = phi ptr addrspace(1) [ %head, %entry ], [ %next, %loop ]
  %next.addr = getelementptr i8, ptr addrspace(1) %p, i64 16
  %next = load ptr addrspace(1), ptr addrspace(1) %next.addr
  %data.addr = getelementptr i8, ptr addrspace(1) %p, i64 24
  %data = load ptr addrspace(1), ptr addrspace(1) %data.addr
  %c = call i1 @jeandle.check_instanceof(ptr addrspace(0) inttoptr (i64 7 to ptr addrspace(0)), ptr addrspace(1) nonnull %next)
  br i1 %c, label %loop, label %exit

exit:
  ret void
}

; %next: field next@16 declared as 9 (Object).
; CHECK: %next = load ptr addrspace(1), ptr addrspace(1) %next.addr{{.*}}, !java-klass ![[N:[0-9]+]]
; %data: only recoverable once %p is sharpened to Node (7) — data@24 is klass 8.
; CHECK: %data = load ptr addrspace(1), ptr addrspace(1) %data.addr{{.*}}, !java-klass ![[D:[0-9]+]]
; CHECK: ![[N]] = !{i64 9}
; CHECK: ![[D]] = !{i64 8}

attributes #0 = { "java-method"="0" }

!java-method-compilation = !{}
