; RUN: opt -S -verify-each -passes=constant-field-folding -jeandle-vm-callback-log=%S/Inputs/klass-queries.cblog %s | FileCheck %s

declare hotspotcc i32 @jeandle.klass_modifiers(ptr)
declare hotspotcc i32 @jeandle.klass_access_flags(ptr, i32)
declare hotspotcc ptr @jeandle.klass_super(ptr)
declare i32 @jeandle.klass_modifiers.extra(ptr)

; CHECK-LABEL: @bundled_queries(
; CHECK: call hotspotcc i32 @jeandle.klass_modifiers{{.*}}[ "deopt"
; CHECK: call hotspotcc i32 @jeandle.klass_access_flags{{.*}}[ "deopt"
; CHECK: call hotspotcc ptr @jeandle.klass_super{{.*}}[ "deopt"
define ptr @bundled_queries() {
  %m = call hotspotcc i32 @jeandle.klass_modifiers(ptr inttoptr (i64 123 to ptr)) [ "deopt"(i32 0) ]
  %a = call hotspotcc i32 @jeandle.klass_access_flags(ptr inttoptr (i64 123 to ptr), i32 512) [ "deopt"(i32 0) ]
  %s = call hotspotcc ptr @jeandle.klass_super(ptr inttoptr (i64 123 to ptr)) [ "deopt"(i32 0) ]
  ret ptr %s
}

; CHECK-LABEL: @tail_modifiers(
; CHECK: musttail call hotspotcc i32 @jeandle.klass_modifiers
define hotspotcc i32 @tail_modifiers(ptr %ignored) {
  %m = musttail call hotspotcc i32 @jeandle.klass_modifiers(ptr inttoptr (i64 123 to ptr))
  ret i32 %m
}

; CHECK-LABEL: @tail_access_flags(
; CHECK: musttail call hotspotcc i32 @jeandle.klass_access_flags
define hotspotcc i32 @tail_access_flags(ptr %ignored, i32 %mask) {
  %a = musttail call hotspotcc i32 @jeandle.klass_access_flags(ptr inttoptr (i64 123 to ptr), i32 512)
  ret i32 %a
}

; CHECK-LABEL: @tail_super(
; CHECK: musttail call hotspotcc ptr @jeandle.klass_super
define hotspotcc ptr @tail_super(ptr %ignored) {
  %s = musttail call hotspotcc ptr @jeandle.klass_super(ptr inttoptr (i64 123 to ptr))
  ret ptr %s
}

; CHECK-LABEL: @wrong_modifier_result(
; CHECK: call i64 @jeandle.klass_modifiers
define i64 @wrong_modifier_result() {
  %m = call i64 @jeandle.klass_modifiers(ptr inttoptr (i64 123 to ptr))
  ret i64 %m
}

; CHECK-LABEL: @wrong_flags_mask(
; CHECK: call i32 @jeandle.klass_access_flags{{.*}}i64 512
define i32 @wrong_flags_mask() {
  %a = call i32 @jeandle.klass_access_flags(ptr inttoptr (i64 123 to ptr), i64 512)
  ret i32 %a
}

; CHECK-LABEL: @wrong_super_result(
; CHECK: call ptr addrspace(1) @jeandle.klass_super
define ptr addrspace(1) @wrong_super_result() {
  %s = call ptr addrspace(1) @jeandle.klass_super(ptr inttoptr (i64 123 to ptr))
  ret ptr addrspace(1) %s
}

; CHECK-LABEL: @oop_klass_argument(
; CHECK: call i32 @jeandle.klass_modifiers(ptr addrspace(1)
; CHECK: call i32 @jeandle.klass_access_flags(ptr addrspace(1)
; CHECK: call ptr @jeandle.klass_super(ptr addrspace(1)
define ptr @oop_klass_argument() {
  %m = call i32 @jeandle.klass_modifiers(ptr addrspace(1) inttoptr (i64 123 to ptr addrspace(1)))
  %a = call i32 @jeandle.klass_access_flags(ptr addrspace(1) inttoptr (i64 123 to ptr addrspace(1)), i32 512)
  %s = call ptr @jeandle.klass_super(ptr addrspace(1) inttoptr (i64 123 to ptr addrspace(1)))
  ret ptr %s
}

; CHECK-LABEL: @near_name(
; CHECK: call i32 @jeandle.klass_modifiers.extra
define i32 @near_name() {
  %m = call i32 @jeandle.klass_modifiers.extra(ptr inttoptr (i64 123 to ptr))
  ret i32 %m
}

declare i32 @personality(...)
; CHECK-LABEL: @invoked_modifiers(
; CHECK: invoke hotspotcc i32 @jeandle.klass_modifiers
; CHECK: landingpad
define i32 @invoked_modifiers() personality ptr @personality {
entry:
  %m = invoke hotspotcc i32 @jeandle.klass_modifiers(ptr inttoptr (i64 123 to ptr))
      to label %normal unwind label %exception
normal:
  ret i32 %m
exception:
  %lp = landingpad { ptr, i32 } cleanup
  resume { ptr, i32 } %lp
}

; CHECK-LABEL: @invoked_access_flags(
; CHECK: invoke hotspotcc i32 @jeandle.klass_access_flags
; CHECK: landingpad
define i32 @invoked_access_flags() personality ptr @personality {
entry:
  %a = invoke hotspotcc i32 @jeandle.klass_access_flags(ptr inttoptr (i64 123 to ptr), i32 512)
      to label %normal unwind label %exception
normal:
  ret i32 %a
exception:
  %lp = landingpad { ptr, i32 } cleanup
  resume { ptr, i32 } %lp
}

; CHECK-LABEL: @invoked_super(
; CHECK: invoke hotspotcc ptr @jeandle.klass_super
; CHECK: landingpad
define ptr @invoked_super() personality ptr @personality {
entry:
  %s = invoke hotspotcc ptr @jeandle.klass_super(ptr inttoptr (i64 123 to ptr))
      to label %normal unwind label %exception
normal:
  ret ptr %s
exception:
  %lp = landingpad { ptr, i32 } cleanup
  resume { ptr, i32 } %lp
}

!java-method-compilation = !{}
