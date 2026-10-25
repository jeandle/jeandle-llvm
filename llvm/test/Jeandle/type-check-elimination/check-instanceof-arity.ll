; RUN: opt -S -passes="type-check-elimination" -jeandle-vm-callback-log=%S/Inputs/check-instanceof-arity.cblog %s 2>&1 | FileCheck %s

; The name "jeandle.check_instanceof" is matched, not a type identity: legal
; IR can declare a same-named function with a different signature. The guard
; recognition must not read operands out of bounds — the call simply does not
; match and nothing folds.

declare i1 @jeandle.check_instanceof(ptr)

define i1 @arity_mismatch(ptr %klass) gc "hotspotgc" {
entry:
  %c = call i1 @jeandle.check_instanceof(ptr %klass)
  br i1 %c, label %t, label %f
t:
  ret i1 true
f:
  ; CHECK-LABEL: @arity_mismatch(
  ; CHECK: f:
  ; CHECK-NEXT: %r = call i1 @jeandle.check_instanceof
  ; CHECK-NEXT: ret i1 %r
  %r = call i1 @jeandle.check_instanceof(ptr %klass)
  ret i1 %r
}

!java-method-compilation = !{}
