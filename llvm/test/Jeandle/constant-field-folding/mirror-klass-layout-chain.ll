; RUN: opt -S -passes="constant-field-folding" -jeandle-vm-callback-log=%S/Inputs/mirror-klass-layout-chain.cblog %s 2>&1 | FileCheck %s

@oop_handle_CallSite_0 = external dso_local global ptr addrspace(1)

declare hotspotcc ptr @jeandle.load_mirror_klass(ptr addrspace(1))
declare hotspotcc i32 @jeandle.layout_helper(ptr)

define hotspotcc i32 @fold_constant_field_mirror_layout_chain() #0 gc "hotspotgc" {
entry:
  %callsite = load ptr addrspace(1), ptr @oop_handle_CallSite_0
  %mirror.addr = getelementptr i8, ptr addrspace(1) %callsite, i64 16
  %mirror = load ptr addrspace(1), ptr addrspace(1) %mirror.addr
  %klass = call hotspotcc ptr @jeandle.load_mirror_klass(ptr addrspace(1) %mirror)
  %layout = call hotspotcc i32 @jeandle.layout_helper(ptr %klass)
  ret i32 %layout
}

; CHECK:       @oop_handle_ClassMirror_1 = external dso_local global ptr addrspace(1)
; CHECK-LABEL: define hotspotcc i32 @fold_constant_field_mirror_layout_chain()
; CHECK:         %folded.oop = load ptr addrspace(1), ptr @oop_handle_ClassMirror_1
; CHECK-NEXT:    ret i32 -2147483637

attributes #0 = { "java-method"="1" }

!java-method-compilation = !{}
