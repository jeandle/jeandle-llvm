; RUN: opt -S -passes=jeandle-inline-driver -verify-each -jeandle-vm-callback-log=%S/Inputs/caller-class-call-forms.cblog %s | FileCheck %s --check-prefix=KNOWN
; RUN: opt -S -passes=jeandle-inline-driver -verify-each -jeandle-vm-callback-log=%S/Inputs/caller-class-unknown.cblog %s | FileCheck %s --check-prefix=UNKNOWN
;
; Oop ID zero is a valid GC-safe result. Unknown committed scopes keep their
; invoke and exceptional path. The marker cannot authorize a wrong signature,
; a different calling convention, or an unrelated operand-bundle obligation.

@jeandle.personality = global ptr null

define hotspotcc ptr addrspace(1) @root() #0 gc "hotspotgc" personality ptr @jeandle.personality {
entry:
  %slot = alloca i64
  %result = invoke hotspotcc ptr addrspace(1) @sensitive() #2 [ "deopt"(i32 4, i32 4, i64 327695, ptr %slot) ]
          to label %normal unwind label %unwind
normal:
  ret ptr addrspace(1) %result
unwind:
  %exception = landingpad i64 cleanup
  ret ptr addrspace(1) null
}

define available_externally hotspotcc ptr addrspace(1) @sensitive() #1 gc "hotspotgc" {
entry:
  %slot = alloca i64
  %argument = call hotspotcc ptr addrspace(1) @wrong_argument(i32 1) #3
  %result.type = call hotspotcc i64 @wrong_result() #3
  %convention = call ptr addrspace(1) @wrong_convention() #3
  %bundled = call hotspotcc ptr addrspace(1) @get_caller_class() #3 [ "unknown"() ]
  %unmarked = call hotspotcc ptr addrspace(1) @get_caller_class()
  %caller = call hotspotcc ptr addrspace(1) @get_caller_class() #3 [ "deopt"(i32 3, i32 3, i64 327695, ptr %slot) ]
  ret ptr addrspace(1) %caller
}

declare hotspotcc ptr addrspace(1) @wrong_argument(i32)
declare hotspotcc i64 @wrong_result()
declare ptr addrspace(1) @wrong_convention()
declare hotspotcc ptr addrspace(1) @get_caller_class()

attributes #0 = { "java-method"="1" }
attributes #1 = { "java-method"="101" }
attributes #2 = { "monomorphic-target" }
attributes #3 = { "jeandle-caller-class" }
!java-method-compilation = !{}
!static-call-patch-size = !{!0}
!dynamic-call-patch-size = !{!1}
!0 = !{i32 5}
!1 = !{i32 15}

; KNOWN-LABEL: define hotspotcc ptr addrspace(1) @root(
; KNOWN: {{call|invoke}} hotspotcc ptr addrspace(1) @wrong_argument(i32 1)
; KNOWN: {{call|invoke}} hotspotcc i64 @wrong_result()
; KNOWN: {{call|invoke}} ptr addrspace(1) @wrong_convention()
; KNOWN: {{call|invoke}} hotspotcc ptr addrspace(1) @get_caller_class() {{.*}}[ "unknown"() ]
; KNOWN: {{call|invoke}} hotspotcc ptr addrspace(1) @get_caller_class()
; KNOWN: %[[MIRROR:.*]] = load ptr addrspace(1), ptr @oop_handle_zero
; KNOWN: ret ptr addrspace(1)
; KNOWN: landingpad
; UNKNOWN-LABEL: define hotspotcc ptr addrspace(1) @root(
; UNKNOWN: {{call|invoke}} hotspotcc ptr addrspace(1) @wrong_argument(i32 1)
; UNKNOWN: {{call|invoke}} hotspotcc i64 @wrong_result()
; UNKNOWN: {{call|invoke}} ptr addrspace(1) @wrong_convention()
; UNKNOWN: {{call|invoke}} hotspotcc ptr addrspace(1) @get_caller_class() {{.*}}[ "unknown"() ]
; UNKNOWN: {{call|invoke}} hotspotcc ptr addrspace(1) @get_caller_class()
; UNKNOWN: {{call|invoke}} hotspotcc ptr addrspace(1) @get_caller_class()
; UNKNOWN: landingpad i64
