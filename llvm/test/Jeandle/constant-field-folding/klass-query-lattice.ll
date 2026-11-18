; RUN: opt -S -verify-each -passes=constant-field-folding -jeandle-vm-callback-log=%S/Inputs/klass-query-lattice.cblog %s | FileCheck %s

@oop_handle_Class_0 = external global ptr addrspace(1)
@oop_handle_Other_1 = external global ptr addrspace(1)
@oop_handle_Object_2 = external global ptr addrspace(1)

declare hotspotcc ptr @jeandle.load_mirror_klass(ptr addrspace(1))
declare hotspotcc ptr addrspace(1) @jeandle.get_class(ptr addrspace(1))
declare hotspotcc i32 @jeandle.klass_modifiers(ptr)
declare hotspotcc i32 @jeandle.klass_access_flags(ptr, i32)
declare hotspotcc ptr @jeandle.klass_super(ptr)
declare hotspotcc ptr addrspace(1) @jeandle.klass_mirror(ptr)

; CHECK-LABEL: @same_phi(
; CHECK-NOT: call
; CHECK: ret i32 17
define i32 @same_phi(i1 %condition) {
entry:
  %a = load ptr addrspace(1), ptr @oop_handle_Class_0
  br i1 %condition, label %left, label %right
left:
  br label %join
right:
  %b = load ptr addrspace(1), ptr @oop_handle_Class_0
  br label %join
join:
  %mirror = phi ptr addrspace(1) [ %a, %left ], [ %b, %right ]
  %klass = call hotspotcc ptr @jeandle.load_mirror_klass(ptr addrspace(1) %mirror)
  %modifiers = call hotspotcc i32 @jeandle.klass_modifiers(ptr %klass)
  ret i32 %modifiers
}

; CHECK-LABEL: @conflicting_phi(
; CHECK: call hotspotcc ptr @jeandle.load_mirror_klass
; CHECK: call hotspotcc i32 @jeandle.klass_modifiers
define i32 @conflicting_phi(i1 %condition) {
entry:
  %a = load ptr addrspace(1), ptr @oop_handle_Class_0
  br i1 %condition, label %left, label %right
left:
  br label %join
right:
  %b = load ptr addrspace(1), ptr @oop_handle_Other_1
  br label %join
join:
  %mirror = phi ptr addrspace(1) [ %a, %left ], [ %b, %right ]
  %klass = call hotspotcc ptr @jeandle.load_mirror_klass(ptr addrspace(1) %mirror)
  %modifiers = call hotspotcc i32 @jeandle.klass_modifiers(ptr %klass)
  ret i32 %modifiers
}

; CHECK-LABEL: @same_select(
; CHECK-NOT: call
; CHECK: ret i32 0
define i32 @same_select(i1 %condition) {
  %a = load ptr addrspace(1), ptr @oop_handle_Class_0
  %b = load ptr addrspace(1), ptr @oop_handle_Class_0
  %mirror = select i1 %condition, ptr addrspace(1) %a, ptr addrspace(1) %b
  %klass = call hotspotcc ptr @jeandle.load_mirror_klass(ptr addrspace(1) %mirror)
  %flags = call hotspotcc i32 @jeandle.klass_access_flags(ptr %klass, i32 512)
  ret i32 %flags
}

; CHECK-LABEL: @conflicting_select(
; CHECK: call hotspotcc ptr @jeandle.load_mirror_klass
; CHECK: call hotspotcc i32 @jeandle.klass_access_flags
define i32 @conflicting_select(i1 %condition) {
  %a = load ptr addrspace(1), ptr @oop_handle_Class_0
  %b = load ptr addrspace(1), ptr @oop_handle_Other_1
  %mirror = select i1 %condition, ptr addrspace(1) %a, ptr addrspace(1) %b
  %klass = call hotspotcc ptr @jeandle.load_mirror_klass(ptr addrspace(1) %mirror)
  %flags = call hotspotcc i32 @jeandle.klass_access_flags(ptr %klass, i32 512)
  ret i32 %flags
}

; A self-carrying loop has one grounded mirror identity.
; CHECK-LABEL: @same_loop(
; CHECK-NOT: call
; CHECK: ret i32 17
define i32 @same_loop(i1 %again) {
entry:
  %initial = load ptr addrspace(1), ptr @oop_handle_Class_0
  br label %loop
loop:
  %mirror = phi ptr addrspace(1) [ %initial, %entry ], [ %mirror, %loop ]
  %klass = call hotspotcc ptr @jeandle.load_mirror_klass(ptr addrspace(1) %mirror)
  %flags = call hotspotcc i32 @jeandle.klass_modifiers(ptr %klass)
  br i1 %again, label %loop, label %exit
exit:
  ret i32 %flags
}

; A different backedge identity must invalidate the initial constant.
; CHECK-LABEL: @changing_loop(
; CHECK: call hotspotcc ptr @jeandle.load_mirror_klass
; CHECK: call hotspotcc i32 @jeandle.klass_modifiers
define i32 @changing_loop(i1 %again) {
entry:
  %initial = load ptr addrspace(1), ptr @oop_handle_Class_0
  %other = load ptr addrspace(1), ptr @oop_handle_Other_1
  br label %loop
loop:
  %mirror = phi ptr addrspace(1) [ %initial, %entry ], [ %other, %loop ]
  %klass = call hotspotcc ptr @jeandle.load_mirror_klass(ptr addrspace(1) %mirror)
  %flags = call hotspotcc i32 @jeandle.klass_modifiers(ptr %klass)
  br i1 %again, label %loop, label %exit
exit:
  ret i32 %flags
}

; CHECK-LABEL: @defined_freeze(
; CHECK-NOT: call
; CHECK: ret i32 17
define i32 @defined_freeze(i1 noundef %condition) {
  %a = load ptr addrspace(1), ptr @oop_handle_Class_0, !noundef !0
  %selected = select i1 %condition, ptr addrspace(1) %a, ptr addrspace(1) %a
  %mirror = freeze ptr addrspace(1) %selected
  %klass = call hotspotcc ptr @jeandle.load_mirror_klass(ptr addrspace(1) %mirror)
  %flags = call hotspotcc i32 @jeandle.klass_modifiers(ptr %klass)
  ret i32 %flags
}

; Poison can make freeze choose a different mirror even with identical arms.
; CHECK-LABEL: @unknown_freeze(
; CHECK: call hotspotcc ptr @jeandle.load_mirror_klass
; CHECK: call hotspotcc i32 @jeandle.klass_modifiers
define i32 @unknown_freeze(i1 %condition) {
  %a = load ptr addrspace(1), ptr @oop_handle_Class_0, !noundef !0
  %selected = select i1 %condition, ptr addrspace(1) %a, ptr addrspace(1) %a
  %mirror = freeze ptr addrspace(1) %selected
  %klass = call hotspotcc ptr @jeandle.load_mirror_klass(ptr addrspace(1) %mirror)
  %flags = call hotspotcc i32 @jeandle.klass_modifiers(ptr %klass)
  ret i32 %flags
}

; New mirrors feed the existing ConstOop lattice on the next folding round.
; CHECK-LABEL: @object_super_mirror_chain(
; CHECK-NOT: call
; CHECK: load ptr addrspace(1), ptr @oop_handle_Other_1
; CHECK: ret i32 0
define i32 @object_super_mirror_chain() {
  %object = load ptr addrspace(1), ptr @oop_handle_Object_2
  %mirror = call hotspotcc ptr addrspace(1) @jeandle.get_class(ptr addrspace(1) %object)
  %klass = call hotspotcc ptr @jeandle.load_mirror_klass(ptr addrspace(1) %mirror)
  %super = call hotspotcc ptr @jeandle.klass_super(ptr %klass)
  %super.mirror = call hotspotcc ptr addrspace(1) @jeandle.klass_mirror(ptr %super)
  %super.klass = call hotspotcc ptr @jeandle.load_mirror_klass(ptr addrspace(1) %super.mirror)
  %flags = call hotspotcc i32 @jeandle.klass_modifiers(ptr %super.klass)
  ret i32 %flags
}

; Constant raw Klass merges reuse LVI without adding another lattice.
; CHECK-LABEL: @same_klass_select(
; CHECK-NOT: call
; CHECK: ret i32 17
define i32 @same_klass_select(i1 %condition) {
  %klass = select i1 %condition, ptr inttoptr (i64 123 to ptr), ptr inttoptr (i64 123 to ptr)
  %flags = call hotspotcc i32 @jeandle.klass_modifiers(ptr %klass)
  ret i32 %flags
}

; CHECK-LABEL: @different_klass_select(
; CHECK: call hotspotcc i32 @jeandle.klass_modifiers
define i32 @different_klass_select(i1 %condition) {
  %klass = select i1 %condition, ptr inttoptr (i64 123 to ptr), ptr inttoptr (i64 234 to ptr)
  %flags = call hotspotcc i32 @jeandle.klass_modifiers(ptr %klass)
  ret i32 %flags
}

; CHECK-LABEL: @frozen_poison_klass(
; CHECK: call hotspotcc i32 @jeandle.klass_modifiers
define i32 @frozen_poison_klass() {
  %selected = select i1 poison, ptr inttoptr (i64 123 to ptr), ptr inttoptr (i64 123 to ptr)
  %klass = freeze ptr %selected
  %flags = call hotspotcc i32 @jeandle.klass_modifiers(ptr %klass)
  ret i32 %flags
}

!java-method-compilation = !{}
!0 = !{}
