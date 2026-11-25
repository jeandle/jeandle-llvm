; RUN: opt -S -verify-each -passes=constant-field-folding -jeandle-vm-callback-log=%S/Inputs/array-subtype-layout.cblog %s | FileCheck %s

; Covariant array types do not identify the dynamic Klass, but all their
; subtypes have the same array tag, header size and element size.
declare hotspotcc ptr @jeandle.load_klass(ptr addrspace(1))
declare hotspotcc i32 @jeandle.layout_helper(ptr)

define i32 @object_array(ptr addrspace(1) nonnull "java-klass"="201" %array) {
  %klass = call hotspotcc ptr @jeandle.load_klass(ptr addrspace(1) %array)
  %layout = call hotspotcc i32 @jeandle.layout_helper(ptr %klass)
  ret i32 %layout
}

; CHECK-LABEL: define i32 @object_array(
; CHECK: %klass = call hotspotcc ptr @jeandle.load_klass(ptr addrspace(1) %array)
; CHECK-NOT: @jeandle.layout_helper
; CHECK: ret i32 -2146435070

define i32 @string_array(ptr addrspace(1) nonnull "java-klass"="202" %array) {
  %klass = call hotspotcc ptr @jeandle.load_klass(ptr addrspace(1) %array)
  %layout = call hotspotcc i32 @jeandle.layout_helper(ptr %klass)
  ret i32 %layout
}

; CHECK-LABEL: define i32 @string_array(
; CHECK: %klass = call hotspotcc ptr @jeandle.load_klass(ptr addrspace(1) %array)
; CHECK-NOT: @jeandle.layout_helper
; CHECK: ret i32 -2146435070

define i32 @primitive_array(ptr addrspace(1) nonnull "java-klass"="205" %array) {
  %klass = call hotspotcc ptr @jeandle.load_klass(ptr addrspace(1) %array)
  %layout = call hotspotcc i32 @jeandle.layout_helper(ptr %klass)
  ret i32 %layout
}

; CHECK-LABEL: define i32 @primitive_array(
; CHECK-NOT: @jeandle.layout_helper
; CHECK: ret i32 -1072693246

; The query is dominated by a null guard even though the argument itself is
; nullable. The null exit must survive while the guarded layout can fold.
define i32 @guarded_array(ptr addrspace(1) "java-klass"="201" %array) {
entry:
  %null = icmp eq ptr addrspace(1) %array, null
  br i1 %null, label %null_exit, label %nonnull
nonnull:
  %klass = call hotspotcc ptr @jeandle.load_klass(ptr addrspace(1) %array)
  %layout = call hotspotcc i32 @jeandle.layout_helper(ptr %klass)
  ret i32 %layout
null_exit:
  ret i32 0
}

; CHECK-LABEL: define i32 @guarded_array(
; CHECK: br i1 %null, label %null_exit, label %nonnull
; CHECK: nonnull:
; CHECK: %klass = call hotspotcc ptr @jeandle.load_klass(ptr addrspace(1) %array)
; CHECK-NOT: @jeandle.layout_helper
; CHECK: ret i32 -2146435070
; CHECK: null_exit:
; CHECK-NEXT: ret i32 0

; A non-exact instance type does not determine its subtype's object size.
define i32 @instance_subtype(ptr addrspace(1) nonnull "java-klass"="203" %object) {
  %klass = call hotspotcc ptr @jeandle.load_klass(ptr addrspace(1) %object)
  %layout = call hotspotcc i32 @jeandle.layout_helper(ptr %klass)
  ret i32 %layout
}

; CHECK-LABEL: define i32 @instance_subtype(
; CHECK: %klass = call hotspotcc ptr @jeandle.load_klass(ptr addrspace(1) %object)
; CHECK-NEXT: %layout = call hotspotcc i32 @jeandle.layout_helper(ptr %klass)
; CHECK-NEXT: ret i32 %layout

; Cloneable may denote either an array or an ordinary object.
define i32 @interface_type(ptr addrspace(1) nonnull "java-klass"="204" %object) {
  %klass = call hotspotcc ptr @jeandle.load_klass(ptr addrspace(1) %object)
  %layout = call hotspotcc i32 @jeandle.layout_helper(ptr %klass)
  ret i32 %layout
}

; CHECK-LABEL: define i32 @interface_type(
; CHECK: %klass = call hotspotcc ptr @jeandle.load_klass(ptr addrspace(1) %object)
; CHECK-NEXT: %layout = call hotspotcc i32 @jeandle.layout_helper(ptr %klass)
; CHECK-NEXT: ret i32 %layout

define i32 @nullable_array(ptr addrspace(1) "java-klass"="201" %array) {
  %klass = call hotspotcc ptr @jeandle.load_klass(ptr addrspace(1) %array)
  %layout = call hotspotcc i32 @jeandle.layout_helper(ptr %klass)
  ret i32 %layout
}

; CHECK-LABEL: define i32 @nullable_array(
; CHECK: %klass = call hotspotcc ptr @jeandle.load_klass(ptr addrspace(1) %array)
; CHECK-NEXT: %layout = call hotspotcc i32 @jeandle.layout_helper(ptr %klass)
; CHECK-NEXT: ret i32 %layout

define i32 @unknown_object(ptr addrspace(1) nonnull %object) {
  %klass = call hotspotcc ptr @jeandle.load_klass(ptr addrspace(1) %object)
  %layout = call hotspotcc i32 @jeandle.layout_helper(ptr %klass)
  ret i32 %layout
}

; CHECK-LABEL: define i32 @unknown_object(
; CHECK: %klass = call hotspotcc ptr @jeandle.load_klass(ptr addrspace(1) %object)
; CHECK-NEXT: %layout = call hotspotcc i32 @jeandle.layout_helper(ptr %klass)
; CHECK-NEXT: ret i32 %layout

; An arbitrary native pointer is not evidence about an array Klass.
define i32 @unknown_klass(ptr %klass) {
  %layout = call hotspotcc i32 @jeandle.layout_helper(ptr %klass)
  ret i32 %layout
}

; CHECK-LABEL: define i32 @unknown_klass(
; CHECK: %layout = call hotspotcc i32 @jeandle.layout_helper(ptr %klass)
; CHECK-NEXT: ret i32 %layout

!java-method-compilation = !{}
