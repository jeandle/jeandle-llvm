; RUN: opt -S -passes="type-check-elimination" -jeandle-vm-callback-log=%S/Inputs/array-store-check.cblog %s 2>&1 | FileCheck %s

; Non-PEA elimination of jeandle.array_store_check. The destination array must
; have an exact runtime klass before its element klass can prove compatibility.
; The exception is a constant null value, which is assignable to every reference
; array independently of array covariance.

declare ptr addrspace(1) @make_array()
declare i1 @jeandle.array_store_check(ptr addrspace(1), ptr addrspace(1))

; Models the frontend's exact return attributes on a new Object[] allocation.
; Object[] accepts an unknown reference value.
define i1 @exact_object_array_unknown(ptr addrspace(1) %value)
    gc "hotspotgc" {
entry:
  %array = call "java-klass"="100" "java-klass-exact" ptr addrspace(1) @make_array()
  %result = call i1 @jeandle.array_store_check(
      ptr addrspace(1) %value, ptr addrspace(1) %array)
  ret i1 %result
}

; An exact StringLike[] accepts a value with a known subtype klass.
define i1 @exact_array_known_subtype(
    ptr addrspace(1) "java-klass"="300" %value,
    ptr addrspace(1) "java-klass"="200" "java-klass-exact" %array)
    gc "hotspotgc" {
entry:
  %result = call i1 @jeandle.array_store_check(
      ptr addrspace(1) %value, ptr addrspace(1) %array)
  ret i1 %result
}

; null is compatible even when the array type is not exact.
define i1 @null_value(ptr addrspace(1) %array) gc "hotspotgc" {
entry:
  %result = call i1 @jeandle.array_store_check(
      ptr addrspace(1) null, ptr addrspace(1) %array)
  ret i1 %result
}

; A declared Object[] may be a covariant subtype such as String[], so a
; non-exact destination must retain the runtime check.
define i1 @non_exact_array(
    ptr addrspace(1) %value,
    ptr addrspace(1) "java-klass"="100" %array) gc "hotspotgc" {
entry:
  %result = call i1 @jeandle.array_store_check(
      ptr addrspace(1) %value, ptr addrspace(1) %array)
  ret i1 %result
}

; An exact non-Object array still needs a check when the value type is unknown.
define i1 @exact_array_unknown_value(
    ptr addrspace(1) %value,
    ptr addrspace(1) "java-klass"="200" "java-klass-exact" %array)
    gc "hotspotgc" {
entry:
  %result = call i1 @jeandle.array_store_check(
      ptr addrspace(1) %value, ptr addrspace(1) %array)
  ret i1 %result
}

; Even an exact, incompatible JavaType does not prove that the value is
; non-null. Preserve the check so a runtime null still succeeds.
define i1 @exact_array_incompatible_nullable_value(
    ptr addrspace(1) "java-klass"="400" "java-klass-exact" %value,
    ptr addrspace(1) "java-klass"="200" "java-klass-exact" %array)
    gc "hotspotgc" {
entry:
  %result = call i1 @jeandle.array_store_check(
      ptr addrspace(1) %value, ptr addrspace(1) %array)
  ret i1 %result
}

; ArrayElementKlass returning zero is not enough to distinguish primitive-array
; input from unavailable metadata, so preserve the check conservatively.
define i1 @zero_element_klass(
    ptr addrspace(1) %value,
    ptr addrspace(1) "java-klass"="500" "java-klass-exact" %array)
    gc "hotspotgc" {
entry:
  %result = call i1 @jeandle.array_store_check(
      ptr addrspace(1) %value, ptr addrspace(1) %array)
  ret i1 %result
}

; CHECK-LABEL: define i1 @exact_object_array_unknown(
; CHECK: %array = call "java-klass"="100" "java-klass-exact" ptr addrspace(1) @make_array()
; CHECK-NEXT: ret i1 true

; CHECK-LABEL: define i1 @exact_array_known_subtype(
; CHECK-NEXT: entry:
; CHECK-NEXT: ret i1 true

; CHECK-LABEL: define i1 @null_value(
; CHECK-NEXT: entry:
; CHECK-NEXT: ret i1 true

; CHECK-LABEL: define i1 @non_exact_array(
; CHECK: %result = call i1 @jeandle.array_store_check
; CHECK-NEXT: ret i1 %result

; CHECK-LABEL: define i1 @exact_array_unknown_value(
; CHECK: %result = call i1 @jeandle.array_store_check
; CHECK-NEXT: ret i1 %result

; CHECK-LABEL: define i1 @exact_array_incompatible_nullable_value(
; CHECK: %result = call i1 @jeandle.array_store_check
; CHECK-NEXT: ret i1 %result

; CHECK-LABEL: define i1 @zero_element_klass(
; CHECK: %result = call i1 @jeandle.array_store_check
; CHECK-NEXT: ret i1 %result

!java-method-compilation = !{}
