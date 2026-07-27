; RUN: opt -S -passes="recover-type-info" -jeandle-vm-callback-log=%S/Inputs/recover-loop-widening.cblog %s 2>&1 | FileCheck %s

; Loop where the back-edge value's type differs from the initializer, forcing a
; genuine widen: %p starts as klass 5, but the loaded field is klass 7. The PHI
; fixes at LCA(5,7)=10, then %next is recomputed against the widened base
; (GetFieldType(10,16)=7) and must remain stable (Known{7}). This is the case a
; single recursive walk without a fixpoint would get wrong.

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

; %next's recovered type is the field type 7 even though %p widened to 10.
; CHECK: %next = load ptr addrspace(1), ptr addrspace(1) %n.addr{{.*}}, !java-klass ![[K:[0-9]+]]
; CHECK: ![[K]] = !{i64 7}

attributes #0 = { "java-method"="0" }

!java-method-compilation = !{}
