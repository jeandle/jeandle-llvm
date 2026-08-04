; RUN: opt -S -passes="constant-field-folding" -jeandle-vm-callback-log=%S/Inputs/klass-layout-chain.cblog %s 2>&1 | FileCheck %s

@oop_handle_Test_0 = external dso_local global ptr addrspace(1)

declare hotspotcc ptr @jeandle.load_klass(ptr addrspace(1))
declare hotspotcc i32 @jeandle.layout_helper(ptr)

define hotspotcc i32 @fold_klass_layout_chain() #0 gc "hotspotgc" {
entry:
  %obj = load ptr addrspace(1), ptr @oop_handle_Test_0
  %klass = call hotspotcc ptr @jeandle.load_klass(ptr addrspace(1) %obj)
  %layout = call hotspotcc i32 @jeandle.layout_helper(ptr %klass)
  ret i32 %layout
}

; CHECK-LABEL: define hotspotcc i32 @fold_klass_layout_chain()
; CHECK:       entry:
; CHECK-NEXT:    %obj = load ptr addrspace(1), ptr @oop_handle_Test_0
; CHECK-NEXT:    ret i32 -2147483637

attributes #0 = { "java-method"="1" }

!java-method-compilation = !{}
