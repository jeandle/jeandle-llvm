; RUN: opt -S -passes="constant-field-folding" -jeandle-vm-callback-log=%S/Inputs/mirror-klass-initialized-chain.cblog %s 2>&1 | FileCheck %s

@oop_handle_Class_0 = external global ptr addrspace(1)

declare hotspotcc ptr @jeandle.load_mirror_klass(ptr addrspace(1))
declare hotspotcc i1 @jeandle.klass_is_initialized(ptr)

define hotspotcc i1 @fold_mirror_klass_initialized() #0 gc "hotspotgc" {
entry:
  %mirror = load ptr addrspace(1), ptr @oop_handle_Class_0
  %klass = call hotspotcc ptr @jeandle.load_mirror_klass(ptr addrspace(1) %mirror)
  %initialized = call hotspotcc i1 @jeandle.klass_is_initialized(ptr %klass)
  ret i1 %initialized
}

; CHECK-LABEL: define hotspotcc i1 @fold_mirror_klass_initialized()
; CHECK:       entry:
; CHECK-NEXT:    %mirror = load ptr addrspace(1), ptr @oop_handle_Class_0
; CHECK-NEXT:    ret i1 true

attributes #0 = { "java-method"="1" }

!java-method-compilation = !{}
