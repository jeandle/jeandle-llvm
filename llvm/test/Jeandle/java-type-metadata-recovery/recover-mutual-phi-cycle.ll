; RUN: opt -S -passes="recover-type-info" -jeandle-vm-callback-log=%S/Inputs/recover-mutual-phi-cycle.cblog %s 2>&1 | FileCheck %s

; Two loop PHIs that reference each other on the back-edge (%a reads %b, %b reads
; %a). Both start at Top and must descend together without deadlock. With equal
; seed klasses they fix at klass 5, and the field load off %a recovers to 7.

define void @test(ptr addrspace(1) "java-klass"="5" %a0,
                  ptr addrspace(1) "java-klass"="5" %b0,
                  i1 %cond) #0 gc "hotspotgc" {
entry:
  br label %loop

loop:
  %a = phi ptr addrspace(1) [ %a0, %entry ], [ %b, %loop ]
  %b = phi ptr addrspace(1) [ %b0, %entry ], [ %a, %loop ]
  %a.addr = getelementptr i8, ptr addrspace(1) %a, i64 16
  %fa = load ptr addrspace(1), ptr addrspace(1) %a.addr
  br i1 %cond, label %loop, label %exit

exit:
  ret void
}

; CHECK: %fa = load ptr addrspace(1), ptr addrspace(1) %a.addr{{.*}}, !java-klass ![[K:[0-9]+]]
; CHECK: ![[K]] = !{i64 7}

attributes #0 = { "java-method"="0" }

!java-method-compilation = !{}
