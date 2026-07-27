; RUN: opt -S -passes="recover-type-info" -jeandle-vm-callback-log=%S/Inputs/recover-interface-field-skipped.cblog %s 2>&1 | FileCheck %s

; The field's declared type is an interface (klass 8). IsUnverifiedInterface(8)
; is true, so RecoverTypeInfo must NOT attach metadata — matching the frontend,
; which skips interface-typed fields because the verifier does not enforce them.

define void @test(ptr addrspace(1) "java-klass"="5" %obj) #0 gc "hotspotgc" {
entry:
  %addr = getelementptr i8, ptr addrspace(1) %obj, i64 16
  %field = load ptr addrspace(1), ptr addrspace(1) %addr
  ret void
}

; CHECK: entry:
; No !java-klass must be attached to the load (scoped CHECK-NOT avoids the
; java-klass attribute on the parameter in the function signature).
; CHECK-NOT: java-klass
; CHECK: ret void

attributes #0 = { "java-method"="0" }

!java-method-compilation = !{}
