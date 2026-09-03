; RUN: opt -S -verify-each \
; RUN:   -passes="require<partial-escape-analysis>,partial-escape-transform" \
; RUN:   -jeandle-vm-callback-log=%S/Inputs/690_nested_materialize_sibling_alias.cblog \
; RUN:   %s | FileCheck %s

; Materializing a nested child on one CFG path must not remove the child's
; function-wide SSA aliases.  resolveVirtualRef combines those aliases with
; the current block's ObjectState, so the later-processed virtual sibling must
; still fold its load while the materialized sibling keeps the load real.

@arrayOopDesc.element_size.object = private constant i32 8

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32)
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

; The virtual successor is listed first.  LLVM RPO processes the escape
; successor first; recursively materializing %child there must not delete
; every alias for it before the virtual block is analyzed.
define i32 @nested_escape_before_virtual_sibling(i1 %stay.virtual)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %child = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 69001 to ptr), i32 24, i1 false)
      to label %alloc.holder unwind label %unwind
alloc.holder:
  %holder = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 69002 to ptr), i32 24, i1 false)
      to label %init unwind label %unwind
init:
  %child.value = getelementptr inbounds i8, ptr addrspace(1) %child, i64 16
  store atomic i32 42, ptr addrspace(1) %child.value unordered, align 4
  %holder.child = getelementptr inbounds i8, ptr addrspace(1) %holder, i64 16
  store atomic ptr addrspace(1) %child,
      ptr addrspace(1) %holder.child unordered, align 8
  br i1 %stay.virtual, label %virtual, label %escape
virtual:
  %value = load atomic i32, ptr addrspace(1) %child.value unordered, align 4
  ret i32 %value
escape:
  call void @sink(ptr addrspace(1) %holder)
  ret i32 0
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define i32 @nested_escape_before_virtual_sibling(
; CHECK: virtual:
; CHECK-NOT: load atomic i32
; CHECK: ret i32 42
; CHECK: escape:
; CHECK: %[[CHILD_SLOT:.*]] = getelementptr inbounds i8, ptr addrspace(1) %child, i64 16
; CHECK-NEXT: store atomic i32 42, ptr addrspace(1) %[[CHILD_SLOT]] unordered, align 4
; CHECK: %[[HOLDER_SLOT:.*]] = getelementptr inbounds i8, ptr addrspace(1) %holder, i64 16
; CHECK-NEXT: store atomic ptr addrspace(1) %child, ptr addrspace(1) %[[HOLDER_SLOT]] unordered, align 8
; CHECK: call void @sink(ptr addrspace(1) %holder)

; A second layout keeps one child shared by two parents and Object[].  The
; escape blocks precede the virtual block textually, while RPO still visits
; them first.  Loads through the surviving virtual parent and array recreate
; aliases locally; the direct child alias must also remain available.
define i32 @shared_array_escape_before_virtual_sibling(i1 %stay.virtual)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %child = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 69011 to ptr), i32 24, i1 false)
      to label %alloc.first unwind label %unwind
alloc.first:
  %first = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 69012 to ptr), i32 24, i1 false)
      to label %alloc.second unwind label %unwind
alloc.second:
  %second = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 69013 to ptr), i32 24, i1 false)
      to label %alloc.array unwind label %unwind
alloc.array:
  %array = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
      ptr inttoptr (i64 69014 to ptr), i32 1, i32 24, i32 16, i32 1048576)
      to label %init unwind label %unwind
init:
  %child.value = getelementptr inbounds i8, ptr addrspace(1) %child, i64 16
  store atomic i32 42, ptr addrspace(1) %child.value unordered, align 4
  %first.child = getelementptr inbounds i8, ptr addrspace(1) %first, i64 16
  store atomic ptr addrspace(1) %child,
      ptr addrspace(1) %first.child unordered, align 8
  %second.child = getelementptr inbounds i8, ptr addrspace(1) %second, i64 16
  store atomic ptr addrspace(1) %child,
      ptr addrspace(1) %second.child unordered, align 8
  %array.base = getelementptr inbounds i8, ptr addrspace(1) %array, i64 16
  %array.zero = getelementptr inbounds ptr addrspace(1),
      ptr addrspace(1) %array.base, i64 0
  store atomic ptr addrspace(1) %child,
      ptr addrspace(1) %array.zero unordered, align 8
  br i1 %stay.virtual, label %virtual, label %escape.pre
escape.pre:
  br label %escape
escape:
  call void @sink(ptr addrspace(1) %first)
  ret i32 0
virtual:
  %direct = load atomic i32, ptr addrspace(1) %child.value unordered, align 4
  %from.second = load atomic ptr addrspace(1),
      ptr addrspace(1) %second.child unordered, align 8
  %second.value = getelementptr inbounds i8,
      ptr addrspace(1) %from.second, i64 16
  %via.second =
      load atomic i32, ptr addrspace(1) %second.value unordered, align 4
  %from.array = load atomic ptr addrspace(1),
      ptr addrspace(1) %array.zero unordered, align 8
  %array.value = getelementptr inbounds i8,
      ptr addrspace(1) %from.array, i64 16
  %via.array =
      load atomic i32, ptr addrspace(1) %array.value unordered, align 4
  %sum.0 = add i32 %direct, %via.second
  %sum.1 = add i32 %sum.0, %via.array
  ret i32 %sum.1
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define i32 @shared_array_escape_before_virtual_sibling(
; CHECK: escape:
; CHECK: %[[SHARED_CHILD_SLOT:.*]] = getelementptr inbounds i8, ptr addrspace(1) %child, i64 16
; CHECK-NEXT: store atomic i32 42, ptr addrspace(1) %[[SHARED_CHILD_SLOT]] unordered, align 4
; CHECK: %[[FIRST_SLOT:.*]] = getelementptr inbounds i8, ptr addrspace(1) %first, i64 16
; CHECK-NEXT: store atomic ptr addrspace(1) %child, ptr addrspace(1) %[[FIRST_SLOT]] unordered, align 8
; CHECK: call void @sink(ptr addrspace(1) %first)
; CHECK: virtual:
; CHECK-NOT: load atomic
; CHECK: %[[SUM0:.*]] = add i32 42, 42
; CHECK: %[[SUM1:.*]] = add i32 %[[SUM0]], 42
; CHECK: ret i32 %[[SUM1]]

!java-method-compilation = !{}
