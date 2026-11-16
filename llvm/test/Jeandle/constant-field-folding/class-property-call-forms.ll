; RUN: opt -S -verify-each -passes=constant-field-folding -jeandle-vm-callback-log=%S/Inputs/class-properties.cblog %s | FileCheck %s

@oop_handle_Mirror_0 = external global ptr addrspace(1)
declare hotspotcc i64 @jeandle.class_is_array(ptr addrspace(1))
declare hotspotcc i32 @jeandle.class_is_primitive(ptr)
declare hotspotcc i32 @jeandle.class_get_modifiers(ptr addrspace(1), ...)
declare hotspotcc i32 @jeandle.class_is_hidden(ptr addrspace(1))
declare hotspotcc i32 @jeandle.class_is_interface(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

; CHECK-LABEL: @wrong_return(
; CHECK: call hotspotcc i64 @jeandle.class_is_array
define i64 @wrong_return() {
  %a = load ptr addrspace(1), ptr @oop_handle_Mirror_0
  %r = call hotspotcc i64 @jeandle.class_is_array(ptr addrspace(1) %a)
  ret i64 %r
}

; CHECK-LABEL: @wrong_argument(
; CHECK: call hotspotcc i32 @jeandle.class_is_primitive
define i32 @wrong_argument() {
  %a = load ptr addrspace(1), ptr @oop_handle_Mirror_0
  %b = addrspacecast ptr addrspace(1) %a to ptr
  %r = call hotspotcc i32 @jeandle.class_is_primitive(ptr %b)
  ret i32 %r
}

; CHECK-LABEL: @varargs(
; CHECK: call hotspotcc i32 (ptr addrspace(1), ...) @jeandle.class_get_modifiers
define i32 @varargs() {
  %a = load ptr addrspace(1), ptr @oop_handle_Mirror_0
  %r = call hotspotcc i32 (ptr addrspace(1), ...) @jeandle.class_get_modifiers(ptr addrspace(1) %a)
  ret i32 %r
}

; CHECK-LABEL: @mismatched_prototype(
; CHECK: call hotspotcc i32 @jeandle.class_is_array
define i32 @mismatched_prototype() {
  %a = load ptr addrspace(1), ptr @oop_handle_Mirror_0
  %r = call hotspotcc i32 @jeandle.class_is_array(ptr addrspace(1) %a)
  ret i32 %r
}

; CHECK-LABEL: @wrong_cc(
; CHECK: call i32 @jeandle.class_is_hidden
define i32 @wrong_cc() {
  %a = load ptr addrspace(1), ptr @oop_handle_Mirror_0
  %r = call i32 @jeandle.class_is_hidden(ptr addrspace(1) %a)
  ret i32 %r
}

; CHECK-LABEL: @invoke_query(
; CHECK: invoke hotspotcc i32 @jeandle.class_is_interface
; CHECK: unwind label %unwind
define i32 @invoke_query() personality ptr @__gxx_personality_v0 {
  %a = load ptr addrspace(1), ptr @oop_handle_Mirror_0
  %r = invoke hotspotcc i32 @jeandle.class_is_interface(ptr addrspace(1) %a)
      to label %normal unwind label %unwind
normal:
  ret i32 %r
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}
!java-method-compilation = !{}
