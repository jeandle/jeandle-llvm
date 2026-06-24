; RUN: opt -S -passes=jeandle-inline-driver -jeandle-vm-callback-log=%S/Inputs/global-alias.cblog %s 2>&1 | FileCheck %s

; The replayed callee references a GlobalAlias that is absent from this module.
; The alias should be cloned, wired to its aliasee, and used by the inlined
; body.

@jeandle.personality = global ptr null

define hotspotcc i64 @root() #0 gc "hotspotgc" personality ptr @jeandle.personality {
entry:
  %OrigPcSlot = alloca i64, align 8
  %result = call hotspotcc i64 @callee_global_alias() #2 [ "deopt"(i32 3, i32 3, i64 327695, ptr %OrigPcSlot) ]
  ret i64 %result
}

declare hotspotcc i64 @callee_global_alias() #1 gc "hotspotgc"

attributes #0 = { "java-method"="2" }
attributes #1 = { "java-method"="102" }
attributes #2 = { "monomorphic-target" }

!java-method-compilation = !{}

; CHECK: @inline.alias = alias ptr, inttoptr (i64 4096 to ptr)
; CHECK-LABEL: define hotspotcc i64 @root(
; CHECK-NOT: @callee_global_alias
; CHECK: ret i64 ptrtoint (ptr @inline.alias to i64)
; CHECK-NOT: @callee_global_alias
; CHECK-NOT: define available_externally hotspotcc i64 @callee_global_alias
