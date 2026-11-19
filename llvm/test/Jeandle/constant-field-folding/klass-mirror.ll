; RUN: opt -S -verify-each -passes=constant-field-folding -jeandle-vm-callback-log=%S/Inputs/klass-mirror.cblog %s | FileCheck %s

declare hotspotcc ptr addrspace(1) @jeandle.klass_mirror(ptr)

; Mirror constants must remain GC-visible oop handle loads.
; CHECK-LABEL: @known_mirror(
; CHECK-NOT: call
; CHECK: %[[M:.*]] = load ptr addrspace(1), ptr @oop_handle_Class_7, {{.*}}!nonnull
; CHECK-NEXT: ret ptr addrspace(1) %[[M]]
define ptr addrspace(1) @known_mirror() {
  %mirror = call hotspotcc ptr addrspace(1) @jeandle.klass_mirror(ptr inttoptr (i64 123 to ptr))
  ret ptr addrspace(1) %mirror
}

; Zero is a valid oop handle id.
; CHECK-LABEL: @zero_mirror_id(
; CHECK-NOT: call
; CHECK: load ptr addrspace(1), ptr @oop_handle_Class_0
; CHECK-NEXT: ret ptr addrspace(1)
define ptr addrspace(1) @zero_mirror_id() {
  %mirror = call hotspotcc ptr addrspace(1) @jeandle.klass_mirror(ptr inttoptr (i64 234 to ptr))
  ret ptr addrspace(1) %mirror
}

; CHECK-LABEL: @unavailable_mirror(
; CHECK: %mirror = call hotspotcc ptr addrspace(1) @jeandle.klass_mirror
; CHECK-NEXT: ret ptr addrspace(1) %mirror
define ptr addrspace(1) @unavailable_mirror() {
  %mirror = call hotspotcc ptr addrspace(1) @jeandle.klass_mirror(ptr inttoptr (i64 345 to ptr))
  ret ptr addrspace(1) %mirror
}

; CHECK-LABEL: @dynamic_klass(
; CHECK: call hotspotcc ptr addrspace(1) @jeandle.klass_mirror
define ptr addrspace(1) @dynamic_klass(ptr %klass) {
  %mirror = call hotspotcc ptr addrspace(1) @jeandle.klass_mirror(ptr %klass)
  ret ptr addrspace(1) %mirror
}

; CHECK-LABEL: @null_klass(
; CHECK: call hotspotcc ptr addrspace(1) @jeandle.klass_mirror(ptr null)
define ptr addrspace(1) @null_klass() {
  %mirror = call hotspotcc ptr addrspace(1) @jeandle.klass_mirror(ptr null)
  ret ptr addrspace(1) %mirror
}

; CHECK-LABEL: @bundled_mirror(
; CHECK: call hotspotcc ptr addrspace(1) @jeandle.klass_mirror{{.*}}[ "deopt"
define ptr addrspace(1) @bundled_mirror() {
  %mirror = call hotspotcc ptr addrspace(1) @jeandle.klass_mirror(ptr inttoptr (i64 123 to ptr)) [ "deopt"(i32 0) ]
  ret ptr addrspace(1) %mirror
}

; CHECK-LABEL: @tail_mirror(
; CHECK: musttail call hotspotcc ptr addrspace(1) @jeandle.klass_mirror
define hotspotcc ptr addrspace(1) @tail_mirror(ptr %ignored) {
  %mirror = musttail call hotspotcc ptr addrspace(1) @jeandle.klass_mirror(ptr inttoptr (i64 123 to ptr))
  ret ptr addrspace(1) %mirror
}

; CHECK-LABEL: @wrong_result_type(
; CHECK: call ptr @jeandle.klass_mirror
define ptr @wrong_result_type() {
  %mirror = call ptr @jeandle.klass_mirror(ptr inttoptr (i64 123 to ptr))
  ret ptr %mirror
}

; CHECK-LABEL: @wrong_argument_type(
; CHECK: call ptr addrspace(1) @jeandle.klass_mirror(i64 123)
define ptr addrspace(1) @wrong_argument_type() {
  %mirror = call ptr addrspace(1) @jeandle.klass_mirror(i64 123)
  ret ptr addrspace(1) %mirror
}

; CHECK-LABEL: @wrong_arity(
; CHECK: call ptr addrspace(1) @jeandle.klass_mirror
define ptr addrspace(1) @wrong_arity() {
  %mirror = call ptr addrspace(1) @jeandle.klass_mirror(ptr inttoptr (i64 123 to ptr), i32 0)
  ret ptr addrspace(1) %mirror
}

; CHECK-LABEL: @vararg_mirror(
; CHECK: call ptr addrspace(1) (ptr, ...) @jeandle.klass_mirror
define ptr addrspace(1) @vararg_mirror() {
  %mirror = call ptr addrspace(1) (ptr, ...) @jeandle.klass_mirror(ptr inttoptr (i64 123 to ptr))
  ret ptr addrspace(1) %mirror
}

declare i32 @personality(...)
; CHECK-LABEL: @invoked_mirror(
; CHECK: invoke hotspotcc ptr addrspace(1) @jeandle.klass_mirror
; CHECK: landingpad
define ptr addrspace(1) @invoked_mirror() personality ptr @personality {
entry:
  %mirror = invoke hotspotcc ptr addrspace(1) @jeandle.klass_mirror(ptr inttoptr (i64 123 to ptr))
      to label %normal unwind label %exception
normal:
  ret ptr addrspace(1) %mirror
exception:
  %lp = landingpad { ptr, i32 } cleanup
  resume { ptr, i32 } %lp
}

!java-method-compilation = !{}
