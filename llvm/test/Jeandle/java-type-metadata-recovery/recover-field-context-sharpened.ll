; RUN: opt -S -passes="recover-type-info" -jeandle-vm-callback-log=%S/Inputs/recover-field-context-sharpened.cblog %s 2>&1 | FileCheck %s

; Context-sensitive recovery of a field load: the base is an opaque call
; result (no java-klass return attribute), so the lattice alone proves nothing
; (Bottom). A dominating jeandle.check_instanceof sharpens the base to klass
; 30, which lets RecoverTypeInfo derive the field type at offset 16 (klass 31).

declare ptr addrspace(1) @produce()
declare i1 @jeandle.check_instanceof(ptr addrspace(0), ptr addrspace(1) nonnull)

define void @test() #0 gc "hotspotgc" {
entry:
  %obj = call ptr addrspace(1) @produce()
  %check = call i1 @jeandle.check_instanceof(ptr addrspace(0) inttoptr (i64 30 to ptr addrspace(0)), ptr addrspace(1) nonnull %obj)
  br i1 %check, label %pass, label %fail

pass:
  %addr = getelementptr i8, ptr addrspace(1) %obj, i64 16
  %field = load ptr addrspace(1), ptr addrspace(1) %addr
  ret void

fail:
  ret void
}

; CHECK: %field = load ptr addrspace(1), ptr addrspace(1) %addr{{.*}}, !java-klass ![[K:[0-9]+]]
; CHECK: ![[K]] = !{i64 31}

attributes #0 = { "java-method"="0" }

!java-method-compilation = !{}
