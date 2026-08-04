; RUN: opt -S -passes="constant-field-folding" -jeandle-vm-callback-log=%S/Inputs/klass-is-initialized.cblog %s 2>&1 | FileCheck %s

declare hotspotcc i1 @jeandle.klass_is_initialized(ptr)

define hotspotcc i1 @fold_initialized() #0 gc "hotspotgc" {
entry:
  %initialized = call hotspotcc i1 @jeandle.klass_is_initialized(ptr inttoptr (i64 123456 to ptr))
  ret i1 %initialized
}

; CHECK-LABEL: define hotspotcc i1 @fold_initialized()
; CHECK:       entry:
; CHECK-NEXT:    ret i1 true

; A false VM answer is not stable: the class can initialize before execution.
define hotspotcc i1 @keep_not_yet_initialized() #0 gc "hotspotgc" {
entry:
  %initialized = call hotspotcc i1 @jeandle.klass_is_initialized(ptr inttoptr (i64 654321 to ptr))
  ret i1 %initialized
}

; CHECK-LABEL: define hotspotcc i1 @keep_not_yet_initialized()
; CHECK:         %initialized = call hotspotcc i1 @jeandle.klass_is_initialized(ptr inttoptr (i64 654321 to ptr))
; CHECK-NEXT:    ret i1 %initialized

define hotspotcc i1 @keep_dynamic(ptr %klass) #0 gc "hotspotgc" {
entry:
  %initialized = call hotspotcc i1 @jeandle.klass_is_initialized(ptr %klass)
  ret i1 %initialized
}

; CHECK-LABEL: define hotspotcc i1 @keep_dynamic(
; CHECK:         %initialized = call hotspotcc i1 @jeandle.klass_is_initialized(ptr %klass)
; CHECK-NEXT:    ret i1 %initialized

define hotspotcc i1 @keep_null() #0 gc "hotspotgc" {
entry:
  %initialized = call hotspotcc i1 @jeandle.klass_is_initialized(ptr null)
  ret i1 %initialized
}

; CHECK-LABEL: define hotspotcc i1 @keep_null()
; CHECK:         %initialized = call hotspotcc i1 @jeandle.klass_is_initialized(ptr null)
; CHECK-NEXT:    ret i1 %initialized

attributes #0 = { "java-method"="1" }

!java-method-compilation = !{}
