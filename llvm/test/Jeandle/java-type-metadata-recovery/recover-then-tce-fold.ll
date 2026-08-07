; RUN: opt -S -passes="recover-type-info,type-check-elimination" -jeandle-vm-callback-log=%S/Inputs/recover-then-tce-fold.cblog %s 2>&1 | FileCheck %s

; End-to-end: RecoverTypeInfo re-attaches !java-klass to the field load, then
; TypeCheckElimination uses it to fold the instanceof (the field's recovered
; klass 7 is a subtype of the queried klass 7) to constant true. This is the
; whole point of the pass — restoring type info that load CSE dropped.

declare i1 @jeandle.check_instanceof(ptr, ptr addrspace(1) nonnull)

define i1 @test(ptr addrspace(1) "java-klass"="5" %obj) #0 gc "hotspotgc" {
entry:
  %addr = getelementptr i8, ptr addrspace(1) %obj, i64 16
  %field = load ptr addrspace(1), ptr addrspace(1) %addr
  %r = call i1 @jeandle.check_instanceof(ptr inttoptr (i64 7 to ptr), ptr addrspace(1) nonnull %field)
  ret i1 %r
}

; CHECK: ret i1 true

attributes #0 = { "java-method"="0" }

!java-method-compilation = !{}
