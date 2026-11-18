; RUN: opt -S -passes=jeandle-inline-driver -verify-each -jeandle-vm-callback-log=%S/Inputs/caller-class-fallback.cblog %s | FileCheck %s --implicit-check-not='!inline-scope-id'
;
; A compiled sensitive root has no committed caller scope. Malformed or stale
; scheduling metadata and unsupported call signatures must remain ordinary
; fallbacks, including their live exception edges.

@jeandle.personality = global ptr null

define hotspotcc ptr addrspace(1) @root(i1 %bad.scope) #0 gc "hotspotgc" personality ptr @jeandle.personality {
entry:
  br i1 %bad.scope, label %stale, label %boundary

boundary:
  %first = invoke hotspotcc ptr addrspace(1) @get_caller_class() #1
          to label %normal unwind label %unwind

stale:
  %second = invoke hotspotcc ptr addrspace(1) @get_caller_class() #1
          to label %normal unwind label %unwind, !inline-scope-id !0

normal:
  %result = phi ptr addrspace(1) [ %first, %boundary ], [ %second, %stale ]
  ret ptr addrspace(1) %result

unwind:
  %which = phi i32 [ 1, %boundary ], [ 2, %stale ]
  %exception = landingpad i64 cleanup
  ret ptr addrspace(1) null
}

declare hotspotcc ptr addrspace(1) @get_caller_class()
attributes #0 = { "java-method"="1" }
attributes #1 = { "jeandle-caller-class" }
!java-method-compilation = !{}
!0 = !{i32 404}

; CHECK-LABEL: define hotspotcc ptr addrspace(1) @root(
; CHECK: invoke hotspotcc ptr addrspace(1) @get_caller_class()
; CHECK: invoke hotspotcc ptr addrspace(1) @get_caller_class()
; CHECK: phi i32 [ 1, %boundary ], [ 2, %stale ]
; CHECK: landingpad i64
