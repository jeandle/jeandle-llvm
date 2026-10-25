; RUN: opt -S -passes=type-check-elimination -jeandle-vm-callback-log=%S/Inputs/nondefinitive-klass-global.cblog %s | FileCheck %s
@klass_slot = externally_initialized constant ptr inttoptr (i64 9 to ptr)
declare i1 @jeandle.check_instanceof(ptr, ptr addrspace(1) nonnull)
define i1 @external_klass(ptr addrspace(1) "java-klass"="9" "java-klass-exact" %obj) {
  %k = load ptr, ptr @klass_slot
  %r = call i1 @jeandle.check_instanceof(ptr %k, ptr addrspace(1) nonnull %obj)
  ret i1 %r
}
; CHECK-LABEL: define i1 @external_klass
; CHECK: %r = call i1 @jeandle.check_instanceof
; CHECK: ret i1 %r
!java-method-compilation = !{}

@local_slot = internal constant ptr inttoptr (i64 9 to ptr)
@nested_slot = internal alias ptr, ptr @local_slot
@weak_slot = weak alias ptr, ptr @nested_slot

define i1 @weak_alias_klass(ptr addrspace(1) "java-klass"="9" "java-klass-exact" %obj) {
  %wrapped = getelementptr i8, ptr @weak_slot, i64 0
  %k = load ptr, ptr %wrapped
  %r = call i1 @jeandle.check_instanceof(ptr %k, ptr addrspace(1) nonnull %obj)
  ret i1 %r
}
; CHECK-LABEL: define i1 @weak_alias_klass
; CHECK: %r = call i1 @jeandle.check_instanceof
; CHECK: ret i1 %r
