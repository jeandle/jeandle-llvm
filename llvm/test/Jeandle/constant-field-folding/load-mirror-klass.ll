; RUN: opt -S -passes="constant-field-folding" -jeandle-vm-callback-log=%S/Inputs/load-mirror-klass.cblog %s 2>&1 | FileCheck %s

@oop_handle_ClassMirror_0 = external dso_local global ptr addrspace(1)
@oop_handle_PrimitiveMirror_1 = external dso_local global ptr addrspace(1)
@oop_handle_Unknown_2 = external dso_local global ptr addrspace(1)

declare hotspotcc ptr @jeandle.load_mirror_klass(ptr addrspace(1))

define hotspotcc ptr @fold_reference_mirror() #0 gc "hotspotgc" {
entry:
  %mirror = load ptr addrspace(1), ptr @oop_handle_ClassMirror_0
  %klass = call hotspotcc ptr @jeandle.load_mirror_klass(ptr addrspace(1) %mirror)
  ret ptr %klass
}

; CHECK-LABEL: define hotspotcc ptr @fold_reference_mirror()
; CHECK:       entry:
; CHECK-NEXT:    %mirror = load ptr addrspace(1), ptr @oop_handle_ClassMirror_0
; CHECK-NEXT:    ret ptr inttoptr (i64 234567 to ptr)

define hotspotcc ptr @keep_dynamic(ptr addrspace(1) %mirror) #0 gc "hotspotgc" {
entry:
  %klass = call hotspotcc ptr @jeandle.load_mirror_klass(ptr addrspace(1) %mirror)
  ret ptr %klass
}

; CHECK-LABEL: define hotspotcc ptr @keep_dynamic(
; CHECK:         %klass = call hotspotcc ptr @jeandle.load_mirror_klass(ptr addrspace(1) %mirror)
; CHECK-NEXT:    ret ptr %klass

define hotspotcc ptr @fold_primitive_mirror_to_null() #0 gc "hotspotgc" {
entry:
  %mirror = load ptr addrspace(1), ptr @oop_handle_PrimitiveMirror_1
  %klass = call hotspotcc ptr @jeandle.load_mirror_klass(ptr addrspace(1) %mirror)
  ret ptr %klass
}

; CHECK-LABEL: define hotspotcc ptr @fold_primitive_mirror_to_null()
; CHECK:       entry:
; CHECK-NEXT:    %mirror = load ptr addrspace(1), ptr @oop_handle_PrimitiveMirror_1
; CHECK-NEXT:    ret ptr null

define hotspotcc ptr @keep_non_mirror_or_unavailable() #0 gc "hotspotgc" {
entry:
  %mirror = load ptr addrspace(1), ptr @oop_handle_Unknown_2
  %klass = call hotspotcc ptr @jeandle.load_mirror_klass(ptr addrspace(1) %mirror)
  ret ptr %klass
}

; CHECK-LABEL: define hotspotcc ptr @keep_non_mirror_or_unavailable()
; CHECK:         %klass = call hotspotcc ptr @jeandle.load_mirror_klass(ptr addrspace(1) %mirror)
; CHECK-NEXT:    ret ptr %klass

attributes #0 = { "java-method"="1" }

!java-method-compilation = !{}
