; RUN: opt -S -passes="recover-type-info" -jeandle-vm-callback-log=%S/Inputs/recover-loop-unknown-init.cblog %s 2>&1 | FileCheck %s

; Loop PHI whose initializer has NO java-klass attribute (opaque argument). The
; base is Bottom, so %p and %next stay Bottom and no metadata is attached.
; Soundness check: we must not invent a klass.

define void @test(ptr addrspace(1) %head, i1 %cond) #0 gc "hotspotgc" {
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

; CHECK-NOT: java-klass

attributes #0 = { "java-method"="0" }

!java-method-compilation = !{}
