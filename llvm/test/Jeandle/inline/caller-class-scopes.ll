; RUN: opt -S -passes=jeandle-inline-driver -verify-each -jeandle-vm-callback-log=%S/Inputs/caller-class-scopes.cblog %s | FileCheck %s
; RUN: opt -S -passes=jeandle-inline-driver -verify-each %s | FileCheck %s --check-prefix=NO-CALLBACKS
;
; One cached sensitive inlinee is reused below A and B. Its root copies must
; use the containing committed scope, and deleting the proven invokes must
; remove both incoming edges of the shared exceptional PHI.

@jeandle.personality = global ptr null

define hotspotcc ptr addrspace(1) @root(i1 %second) #0 gc "hotspotgc" personality ptr @jeandle.personality {
entry:
  %slot = alloca i64
  br i1 %second, label %b, label %a

a:
  %from.a = invoke hotspotcc ptr addrspace(1) @caller_a() #4 [ "deopt"(i32 10, i32 10, i64 327695, ptr %slot) ]
          to label %normal unwind label %unwind

b:
  %from.b = invoke hotspotcc ptr addrspace(1) @caller_b() #4 [ "deopt"(i32 20, i32 20, i64 327695, ptr %slot) ]
          to label %normal unwind label %unwind

normal:
  %result = phi ptr addrspace(1) [ %from.a, %a ], [ %from.b, %b ]
  ret ptr addrspace(1) %result

unwind:
  %which = phi i32 [ 41, %a ], [ 42, %b ]
  %exception = landingpad i64 cleanup
  ret ptr addrspace(1) null
}

define available_externally hotspotcc ptr addrspace(1) @caller_a() #1 gc "hotspotgc" {
entry:
  %slot = alloca i64
  %result = call hotspotcc ptr addrspace(1) @sensitive() #4 [ "deopt"(i32 1, i32 1, i64 327695, ptr %slot) ]
  ret ptr addrspace(1) %result
}

define available_externally hotspotcc ptr addrspace(1) @caller_b() #2 gc "hotspotgc" {
entry:
  %slot = alloca i64
  %result = call hotspotcc ptr addrspace(1) @sensitive() #4 [ "deopt"(i32 2, i32 2, i64 327695, ptr %slot) ]
  ret ptr addrspace(1) %result
}

define available_externally hotspotcc ptr addrspace(1) @sensitive() #3 gc "hotspotgc" {
entry:
  %slot = alloca i64
  %caller = call hotspotcc ptr addrspace(1) @get_caller_class() #5 [ "deopt"(i32 3, i32 3, i64 327695, ptr %slot) ]
  ret ptr addrspace(1) %caller
}

; This body is not the compiled root, even when it contains a matching marker.
define ptr addrspace(1) @uncompiled_helper() {
  %caller = call hotspotcc ptr addrspace(1) @get_caller_class() #5, !inline-scope-id !2
  ret ptr addrspace(1) %caller
}

declare hotspotcc ptr addrspace(1) @get_caller_class()

attributes #0 = { "java-method"="1" }
attributes #1 = { "java-method"="101" }
attributes #2 = { "java-method"="102" }
attributes #3 = { "java-method"="103" }
attributes #4 = { "monomorphic-target" }
attributes #5 = { "jeandle-caller-class" }

!java-method-compilation = !{}
!static-call-patch-size = !{!0}
!dynamic-call-patch-size = !{!1}
!0 = !{i32 5}
!1 = !{i32 15}
!2 = !{i32 2}

; CHECK-LABEL: define hotspotcc ptr addrspace(1) @root(
; CHECK-NOT: invoke
; CHECK-NOT: @get_caller_class
; CHECK-DAG: load ptr addrspace(1), ptr @oop_handle_501
; CHECK-DAG: load ptr addrspace(1), ptr @oop_handle_502
; CHECK-NOT: landingpad
; CHECK-NOT: @get_caller_class
; CHECK: ret ptr addrspace(1)
; CHECK-LABEL: define ptr addrspace(1) @uncompiled_helper(
; CHECK: call hotspotcc ptr addrspace(1) @get_caller_class()
; CHECK-NOT: define available_externally

; NO-CALLBACKS-LABEL: define hotspotcc ptr addrspace(1) @root(
; NO-CALLBACKS: invoke hotspotcc ptr addrspace(1) @caller_a()
; NO-CALLBACKS: invoke hotspotcc ptr addrspace(1) @caller_b()
; NO-CALLBACKS-LABEL: define available_externally hotspotcc ptr addrspace(1) @sensitive(
; NO-CALLBACKS: call hotspotcc ptr addrspace(1) @get_caller_class()
