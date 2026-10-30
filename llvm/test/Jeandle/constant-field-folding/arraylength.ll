; RUN: opt -S -passes=constant-field-folding -jeandle-vm-callback-log=%S/Inputs/arraylength.cblog -verify-each %s | FileCheck %s

; Array length is immutable independently of element stability. Use a
; nondefault header offset to prove the query comes from VMConstants.
target datalayout = "e-p:64:64-p1:64:64"
@arrayOopDesc.length_offset_in_bytes = private constant i32 20
@oop_handle_Array_0 = external global ptr addrspace(1)
@oop_handle_Empty_1 = external global ptr addrspace(1)
@oop_handle_Mutable_2 = external global ptr addrspace(1)
@oop_handle_Refused_3 = external global ptr addrspace(1)
@oop_handle_WrongType_4 = external global ptr addrspace(1)
@oop_handle_Negative_5 = external global ptr addrspace(1)
@oop_handle_Overflow_6 = external global ptr addrspace(1)
@oop_handle_Other_7 = external global ptr addrspace(1)
declare hotspotcc i32 @jeandle.arraylength(ptr addrspace(1))
declare i32 @jeandle.arraylength.extra(ptr addrspace(1))

; CHECK-LABEL: @known(
; CHECK-NOT: call
; CHECK: ret i32 3
define i32 @known() {
  %a = load ptr addrspace(1), ptr @oop_handle_Array_0
  %n = call hotspotcc i32 @jeandle.arraylength(ptr addrspace(1) %a)
  ret i32 %n
}

; CHECK-LABEL: @empty(
; CHECK-NOT: call
; CHECK: ret i32 0
define i32 @empty() {
  %a = load ptr addrspace(1), ptr @oop_handle_Empty_1
  %n = call hotspotcc i32 @jeandle.arraylength(ptr addrspace(1) %a)
  ret i32 %n
}

; CHECK-LABEL: @mutable_length(
; CHECK-NOT: call
; CHECK: ret i32 3
define i32 @mutable_length() {
  %a = load ptr addrspace(1), ptr @oop_handle_Mutable_2
  %n = call hotspotcc i32 @jeandle.arraylength(ptr addrspace(1) %a)
  ret i32 %n
}

; CHECK-LABEL: @refused(
; CHECK: %n = call hotspotcc i32 @jeandle.arraylength
; CHECK: ret i32 %n
define i32 @refused() {
  %a = load ptr addrspace(1), ptr @oop_handle_Refused_3
  %n = call hotspotcc i32 @jeandle.arraylength(ptr addrspace(1) %a)
  ret i32 %n
}

; CHECK-LABEL: @wrong_type(
; CHECK: %n = call hotspotcc i32 @jeandle.arraylength
; CHECK: ret i32 %n
define i32 @wrong_type() {
  %a = load ptr addrspace(1), ptr @oop_handle_WrongType_4
  %n = call hotspotcc i32 @jeandle.arraylength(ptr addrspace(1) %a)
  ret i32 %n
}

; CHECK-LABEL: @negative(
; CHECK: %n = call hotspotcc i32 @jeandle.arraylength
; CHECK: ret i32 %n
define i32 @negative() {
  %a = load ptr addrspace(1), ptr @oop_handle_Negative_5
  %n = call hotspotcc i32 @jeandle.arraylength(ptr addrspace(1) %a)
  ret i32 %n
}

; CHECK-LABEL: @overflow(
; CHECK: %n = call hotspotcc i32 @jeandle.arraylength
; CHECK: ret i32 %n
define i32 @overflow() {
  %a = load ptr addrspace(1), ptr @oop_handle_Overflow_6
  %n = call hotspotcc i32 @jeandle.arraylength(ptr addrspace(1) %a)
  ret i32 %n
}

; CHECK-LABEL: @mutable_element(
; CHECK-NOT: @jeandle.arraylength
; CHECK: load atomic i8
; CHECK: add i32 {{.*}}, 3
; CHECK: ret i32
define i32 @mutable_element() {
  %a = load ptr addrspace(1), ptr @oop_handle_Mutable_2
  %n = call hotspotcc i32 @jeandle.arraylength(ptr addrspace(1) %a)
  %p = getelementptr i8, ptr addrspace(1) %a, i64 24
  %v = load atomic i8, ptr addrspace(1) %p unordered, align 1
  %z = zext i8 %v to i32
  %r = add i32 %z, %n
  ret i32 %r
}
; CHECK-LABEL: @unknown(
; CHECK: call hotspotcc i32 @jeandle.arraylength
define i32 @unknown(ptr addrspace(1) %a) {
  %n = call hotspotcc i32 @jeandle.arraylength(ptr addrspace(1) %a)
  ret i32 %n
}

; CHECK-LABEL: @null(
; CHECK: call hotspotcc i32 @jeandle.arraylength
define i32 @null() {
  %n = call hotspotcc i32 @jeandle.arraylength(ptr addrspace(1) null)
  ret i32 %n
}

; CHECK-LABEL: @poison(
; CHECK: call hotspotcc i32 @jeandle.arraylength
define i32 @poison() {
  %n = call hotspotcc i32 @jeandle.arraylength(ptr addrspace(1) poison)
  ret i32 %n
}

; CHECK-LABEL: @frozen_poison(
; CHECK: call hotspotcc i32 @jeandle.arraylength
define i32 @frozen_poison() {
  %f = freeze ptr addrspace(1) poison
  %n = call hotspotcc i32 @jeandle.arraylength(ptr addrspace(1) %f)
  ret i32 %n
}

; CHECK-LABEL: @derived(
; CHECK: call hotspotcc i32 @jeandle.arraylength
define i32 @derived() {
  %a = load ptr addrspace(1), ptr @oop_handle_Array_0
  %f = getelementptr i8, ptr addrspace(1) %a, i64 1
  %n = call hotspotcc i32 @jeandle.arraylength(ptr addrspace(1) %f)
  ret i32 %n
}

; CHECK-LABEL: @same_identity(
; CHECK-NOT: call
; CHECK: ret i32 3
define i32 @same_identity(i1 noundef %condition, ptr addrspace(1) %external) {
  %a = load ptr addrspace(1), ptr @oop_handle_Array_0, !noundef !0
  %b = load ptr addrspace(1), ptr @oop_handle_Other_7
  %selected = select i1 %condition, ptr addrspace(1) %a, ptr addrspace(1) %a
  %f = freeze ptr addrspace(1) %selected
  %n = call hotspotcc i32 @jeandle.arraylength(ptr addrspace(1) %f)
  ret i32 %n
}

; CHECK-LABEL: @frozen_unproven_identity(
; CHECK: call hotspotcc i32 @jeandle.arraylength
define i32 @frozen_unproven_identity(i1 noundef %condition) {
  %a = load ptr addrspace(1), ptr @oop_handle_Array_0
  %selected = select i1 %condition, ptr addrspace(1) %a, ptr addrspace(1) %a
  %f = freeze ptr addrspace(1) %selected
  %n = call hotspotcc i32 @jeandle.arraylength(ptr addrspace(1) %f)
  ret i32 %n
}

; CHECK-LABEL: @frozen_unproven_condition(
; CHECK: call hotspotcc i32 @jeandle.arraylength
define i32 @frozen_unproven_condition(i1 %condition) {
  %a = load ptr addrspace(1), ptr @oop_handle_Array_0, !noundef !0
  %selected = select i1 %condition, ptr addrspace(1) %a, ptr addrspace(1) %a
  %f = freeze ptr addrspace(1) %selected
  %n = call hotspotcc i32 @jeandle.arraylength(ptr addrspace(1) %f)
  ret i32 %n
}

; CHECK-LABEL: @different_identity(
; CHECK: call hotspotcc i32 @jeandle.arraylength
define i32 @different_identity(i1 noundef %condition, ptr addrspace(1) %external) {
  %a = load ptr addrspace(1), ptr @oop_handle_Array_0, !noundef !0
  %b = load ptr addrspace(1), ptr @oop_handle_Other_7, !noundef !0
  %selected = select i1 %condition, ptr addrspace(1) %a, ptr addrspace(1) %b
  %f = freeze ptr addrspace(1) %selected
  %n = call hotspotcc i32 @jeandle.arraylength(ptr addrspace(1) %f)
  ret i32 %n
}

; CHECK-LABEL: @null_arm(
; CHECK: call hotspotcc i32 @jeandle.arraylength
define i32 @null_arm(i1 %condition, ptr addrspace(1) %external) {
  %a = load ptr addrspace(1), ptr @oop_handle_Array_0
  %b = load ptr addrspace(1), ptr @oop_handle_Other_7
  %selected = select i1 %condition, ptr addrspace(1) %a, ptr addrspace(1) null
  %f = freeze ptr addrspace(1) %selected
  %n = call hotspotcc i32 @jeandle.arraylength(ptr addrspace(1) %f)
  ret i32 %n
}

; CHECK-LABEL: @poison_arm(
; CHECK: call hotspotcc i32 @jeandle.arraylength
define i32 @poison_arm(i1 %condition, ptr addrspace(1) %external) {
  %a = load ptr addrspace(1), ptr @oop_handle_Array_0
  %b = load ptr addrspace(1), ptr @oop_handle_Other_7
  %selected = select i1 %condition, ptr addrspace(1) %a, ptr addrspace(1) poison
  %f = freeze ptr addrspace(1) %selected
  %n = call hotspotcc i32 @jeandle.arraylength(ptr addrspace(1) %f)
  ret i32 %n
}

; CHECK-LABEL: @unknown_arm(
; CHECK: call hotspotcc i32 @jeandle.arraylength
define i32 @unknown_arm(i1 %condition, ptr addrspace(1) %external) {
  %a = load ptr addrspace(1), ptr @oop_handle_Array_0
  %b = load ptr addrspace(1), ptr @oop_handle_Other_7
  %selected = select i1 %condition, ptr addrspace(1) %a, ptr addrspace(1) %external
  %f = freeze ptr addrspace(1) %selected
  %n = call hotspotcc i32 @jeandle.arraylength(ptr addrspace(1) %f)
  ret i32 %n
}

; CHECK-LABEL: @same_phi(
; CHECK-NOT: call
; CHECK: ret i32 3
define i32 @same_phi(i1 %condition) {
entry:
  %a = load ptr addrspace(1), ptr @oop_handle_Array_0
  br i1 %condition, label %left, label %right
left:
  br label %join
right:
  %b = load ptr addrspace(1), ptr @oop_handle_Array_0
  br label %join
join:
  %a.merge = phi ptr addrspace(1) [ %a, %left ], [ %b, %right ]
  %n = call hotspotcc i32 @jeandle.arraylength(ptr addrspace(1) %a.merge)
  ret i32 %n
}
; CHECK-LABEL: @bundled(
; CHECK: call hotspotcc i32 @jeandle.arraylength{{.*}}[ "deopt"
define i32 @bundled() {
  %a = load ptr addrspace(1), ptr @oop_handle_Array_0
  %n = call hotspotcc i32 @jeandle.arraylength(ptr addrspace(1) %a) [ "deopt"(i32 0) ]
  ret i32 %n
}
; CHECK-LABEL: @near_name(
; CHECK: call i32 @jeandle.arraylength.extra
define i32 @near_name() {
  %a = load ptr addrspace(1), ptr @oop_handle_Array_0
  %n = call i32 @jeandle.arraylength.extra(ptr addrspace(1) %a)
  ret i32 %n
}
; CHECK-LABEL: @wrong_call_type(
; CHECK: call i64 @jeandle.arraylength
define i64 @wrong_call_type() {
  %a = load ptr addrspace(1), ptr @oop_handle_Array_0
  %n = call i64 @jeandle.arraylength(ptr addrspace(1) %a)
  ret i64 %n
}
; CHECK-LABEL: @wrong_pointer_type(
; CHECK: call i32 @jeandle.arraylength(ptr
define i32 @wrong_pointer_type(ptr %a) {
  %n = call i32 @jeandle.arraylength(ptr %a)
  ret i32 %n
}
; CHECK-LABEL: @wrong_arity(
; CHECK: call i32 @jeandle.arraylength
define i32 @wrong_arity() {
  %a = load ptr addrspace(1), ptr @oop_handle_Array_0
  %n = call i32 @jeandle.arraylength(ptr addrspace(1) %a, i32 1)
  ret i32 %n
}
; CHECK-LABEL: @vararg_call(
; CHECK: call i32 (ptr addrspace(1), ...) @jeandle.arraylength
define i32 @vararg_call() {
  %a = load ptr addrspace(1), ptr @oop_handle_Array_0
  %n = call i32 (ptr addrspace(1), ...) @jeandle.arraylength(ptr addrspace(1) %a)
  ret i32 %n
}

declare i32 @personality(...)
; CHECK-LABEL: @invoked(
; CHECK: invoke hotspotcc i32 @jeandle.arraylength
; CHECK: landingpad
define i32 @invoked() personality ptr @personality {
entry:
  %a = load ptr addrspace(1), ptr @oop_handle_Array_0
  %n = invoke hotspotcc i32 @jeandle.arraylength(ptr addrspace(1) %a)
      to label %normal unwind label %exception
normal:
  ret i32 %n
exception:
  %lp = landingpad { ptr, i32 } cleanup
  resume { ptr, i32 } %lp
}
!java-method-compilation = !{}
!0 = !{}
