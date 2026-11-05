; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; A semantic Integer box and an ordinary Integer allocation have the same
; Klass and payload layout, but different materialization identity semantics.
; Case C must reject their merge regardless of incoming order: jeandle.box
; may restore a cached valueOf object, while new_instance must remain fresh.

declare hotspotcc ptr addrspace(1) @jeandle.box(i32, ptr, i64)
declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(ptr addrspace(1))

@instanceOopDesc.base_offset_in_bytes = private constant i32 16
@java_lang_boxing_object.value_offset = private constant i32 16
@java_lang_boxing_object.long_value_offset = private constant i32 16

define void @boxed_first(i1 %condition) gc "hotspotgc" {
entry:
  br i1 %condition, label %boxed.block, label %fresh.block

boxed.block:
  %boxed = call hotspotcc ptr addrspace(1) @jeandle.box(
      i32 4, ptr inttoptr (i64 400 to ptr), i64 0)
  br label %merge

fresh.block:
  %fresh = call hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 400 to ptr), i32 24, i1 false)
  %fresh.value = getelementptr inbounds i8, ptr addrspace(1) %fresh, i64 16
  store i32 0, ptr addrspace(1) %fresh.value
  br label %merge

merge:
  %merged = phi ptr addrspace(1) [ %boxed, %boxed.block ],
                                  [ %fresh, %fresh.block ]
  call void @sink(ptr addrspace(1) %merged)
  ret void
}

; Reverse the PHI incoming order so neither source can donate an incorrect
; BoxedKind merely because it is Case C's reference object.
define void @fresh_first(i1 %condition) gc "hotspotgc" {
entry:
  br i1 %condition, label %boxed.block, label %fresh.block

boxed.block:
  %boxed = call hotspotcc ptr addrspace(1) @jeandle.box(
      i32 4, ptr inttoptr (i64 400 to ptr), i64 0)
  br label %merge

fresh.block:
  %fresh = call hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 400 to ptr), i32 24, i1 false)
  %fresh.value = getelementptr inbounds i8, ptr addrspace(1) %fresh, i64 16
  store i32 0, ptr addrspace(1) %fresh.value
  br label %merge

merge:
  %merged = phi ptr addrspace(1) [ %fresh, %fresh.block ],
                                  [ %boxed, %boxed.block ]
  call void @sink(ptr addrspace(1) %merged)
  ret void
}

; CHECK-LABEL: define void @boxed_first(
; CHECK: boxed.block:
; CHECK: %boxed = call hotspotcc ptr addrspace(1) @jeandle.box
; CHECK: fresh.block:
; CHECK: %fresh = call hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK-NEXT: %pea.matslot = getelementptr inbounds i8, ptr addrspace(1) %fresh, i64 16
; CHECK-NEXT: store atomic i32 0, ptr addrspace(1) %pea.matslot unordered, align 4
; CHECK-NEXT: br label %merge
; CHECK: merge:
; CHECK: %merged = phi ptr addrspace(1) [ %boxed, %boxed.block ], [ %fresh, %fresh.block ]
; CHECK-NEXT: call void @sink(ptr addrspace(1) %merged)

; CHECK-LABEL: define void @fresh_first(
; CHECK: boxed.block:
; CHECK: %boxed = call hotspotcc ptr addrspace(1) @jeandle.box
; CHECK: fresh.block:
; CHECK: %fresh = call hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK-NEXT: %pea.matslot = getelementptr inbounds i8, ptr addrspace(1) %fresh, i64 16
; CHECK-NEXT: store atomic i32 0, ptr addrspace(1) %pea.matslot unordered, align 4
; CHECK-NEXT: br label %merge
; CHECK: merge:
; CHECK: %merged = phi ptr addrspace(1) [ %fresh, %fresh.block ], [ %boxed, %boxed.block ]
; CHECK-NEXT: call void @sink(ptr addrspace(1) %merged)

!java-method-compilation = !{}
