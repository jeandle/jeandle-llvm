; RUN: opt -S -passes="constant-field-folding" -jeandle-vm-callback-log=%S/Inputs/layout-helper-call.cblog %s 2>&1 | FileCheck %s

declare hotspotcc i32 @jeandle.layout_helper(ptr)

define hotspotcc i32 @fold_layout_helper() #0 gc "hotspotgc" {
entry:
  %layout = call hotspotcc i32 @jeandle.layout_helper(ptr inttoptr (i64 123456 to ptr))
  ret i32 %layout
}

; CHECK-LABEL: define hotspotcc i32 @fold_layout_helper()
; CHECK:       entry:
; CHECK-NEXT:    ret i32 -2147483637

define hotspotcc i32 @keep_dynamic(ptr %klass) #0 gc "hotspotgc" {
entry:
  %layout = call hotspotcc i32 @jeandle.layout_helper(ptr %klass)
  ret i32 %layout
}

; CHECK-LABEL: define hotspotcc i32 @keep_dynamic(
; CHECK:         %layout = call hotspotcc i32 @jeandle.layout_helper(ptr %klass)
; CHECK-NEXT:    ret i32 %layout

define hotspotcc i32 @keep_null() #0 gc "hotspotgc" {
entry:
  %layout = call hotspotcc i32 @jeandle.layout_helper(ptr null)
  ret i32 %layout
}

; CHECK-LABEL: define hotspotcc i32 @keep_null()
; CHECK:         %layout = call hotspotcc i32 @jeandle.layout_helper(ptr null)
; CHECK-NEXT:    ret i32 %layout

define hotspotcc i32 @keep_unavailable() #0 gc "hotspotgc" {
entry:
  %layout = call hotspotcc i32 @jeandle.layout_helper(ptr inttoptr (i64 654321 to ptr))
  ret i32 %layout
}

; CHECK-LABEL: define hotspotcc i32 @keep_unavailable()
; CHECK:         %layout = call hotspotcc i32 @jeandle.layout_helper(ptr inttoptr (i64 654321 to ptr))
; CHECK-NEXT:    ret i32 %layout

attributes #0 = { "java-method"="1" }

!java-method-compilation = !{}
