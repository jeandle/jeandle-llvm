; RUN: opt -S -passes="constant-field-folding" -jeandle-vm-callback-log=%S/Inputs/mirror-array-klass.cblog %s | FileCheck %s

@oop_handle_IntMirror_0 = external global ptr addrspace(1)
@oop_handle_VoidMirror_1 = external global ptr addrspace(1)
@oop_handle_Unknown_2 = external global ptr addrspace(1)

declare hotspotcc ptr @jeandle.load_mirror_array_klass(ptr addrspace(1))
declare hotspotcc i32 @jeandle.layout_helper(ptr)

; The array Klass query must expose a constant layout recipe to allocation.
define hotspotcc i32 @primitive_layout() #0 gc "hotspotgc" {
  %mirror = load ptr addrspace(1), ptr @oop_handle_IntMirror_0
  %klass = call hotspotcc ptr @jeandle.load_mirror_array_klass(ptr addrspace(1) %mirror)
  %layout = call hotspotcc i32 @jeandle.layout_helper(ptr %klass)
  ret i32 %layout
}
; CHECK-LABEL: define hotspotcc i32 @primitive_layout()
; CHECK-NOT: call hotspotcc
; CHECK: ret i32 -1072690686

define hotspotcc ptr @void_mirror() #0 gc "hotspotgc" {
  %mirror = load ptr addrspace(1), ptr @oop_handle_VoidMirror_1
  %klass = call hotspotcc ptr @jeandle.load_mirror_array_klass(ptr addrspace(1) %mirror)
  ret ptr %klass
}
; CHECK-LABEL: define hotspotcc ptr @void_mirror()
; CHECK-NOT: call hotspotcc
; CHECK: ret ptr null

define hotspotcc ptr @unknown_mirror() #0 gc "hotspotgc" {
  %mirror = load ptr addrspace(1), ptr @oop_handle_Unknown_2
  %klass = call hotspotcc ptr @jeandle.load_mirror_array_klass(ptr addrspace(1) %mirror)
  ret ptr %klass
}
; CHECK-LABEL: define hotspotcc ptr @unknown_mirror()
; CHECK: call hotspotcc ptr @jeandle.load_mirror_array_klass

define hotspotcc ptr @dynamic_mirror(ptr addrspace(1) %mirror) #0 gc "hotspotgc" {
  %klass = call hotspotcc ptr @jeandle.load_mirror_array_klass(ptr addrspace(1) %mirror)
  ret ptr %klass
}
; CHECK-LABEL: define hotspotcc ptr @dynamic_mirror(
; CHECK: call hotspotcc ptr @jeandle.load_mirror_array_klass

attributes #0 = { "java-method"="1" }
!java-method-compilation = !{}
