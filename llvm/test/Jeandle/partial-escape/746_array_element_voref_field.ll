; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" -jeandle-vm-callback-log=%S/Inputs/746_array_element_voref_field.cblog %s | FileCheck %s

; Object[] virtual whose element 0 holds a virtual instance. The instance's
; field is stored, the instance is stored into the array, then the element is
; reloaded and the field is read THROUGH that reload. PEA must (a) track the
; element as a VirtualRef to the instance, (b) on reload create an alias to the
; instance, and (c) fold the field read through the alias to the tracked field
; value — eliminating the array, the instance, all stores, and all loads.
; This is the scalar-replacement analog of `array[0]=child; loaded=array[0];
; loaded.value`; in the full pipeline GVN forwards the element load before PEA
; sees it, so this fixture verifies PEA's own alias-creation and nested-field
; fold in isolation.

@arrayOopDesc.element_size.object = private constant i32 8

declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32)
declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare i32 @__gxx_personality_v0(...)

define i32 @test_obj_array_element_voref_field(i32 %val) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %arr = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
            ptr inttoptr (i64 54004 to ptr), i32 1, i32 32, i32 16, i32 1048576)
         to label %alloc_arr unwind label %u
alloc_arr:
  %child = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 54005 to ptr), i32 16, i1 false)
         to label %body unwind label %u
body:
  ; child.field (offset 8) = %val
  %cf = getelementptr inbounds i8, ptr addrspace(1) %child, i64 8
  store atomic i32 %val, ptr addrspace(1) %cf unordered, align 4
  ; array[0] (base 16, scale 8, index 0) = child
  %base = getelementptr inbounds i8, ptr addrspace(1) %arr, i32 16
  %e0 = getelementptr inbounds ptr addrspace(1), ptr addrspace(1) %base, i64 0
  store atomic ptr addrspace(1) %child, ptr addrspace(1) %e0 unordered, align 8
  ; reload array[0], then read .field through the reload
  %loaded = load atomic ptr addrspace(1), ptr addrspace(1) %e0 unordered, align 8
  %lf = getelementptr inbounds i8, ptr addrspace(1) %loaded, i64 8
  %lv = load atomic i32, ptr addrspace(1) %lf unordered, align 4
  ret i32 %lv
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; The element reload aliases to the (eliminated) instance and the field read
; folds to %val; both allocations, all stores, and all loads are gone.
; CHECK-LABEL: define i32 @test_obj_array_element_voref_field
; CHECK-NOT: jeandle.new_array
; CHECK-NOT: jeandle.new_instance
; CHECK-NOT: store
; CHECK-NOT: load
; CHECK: ret i32 %val

!java-method-compilation = !{}
