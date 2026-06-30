; RUN: opt -S -passes=jeandle-inline-driver -jeandle-vm-callback-log=%S/Inputs/statepoint-id.cblog %s 2>&1 | FileCheck %s

; Inlined call sites carry statepoint-id attributes cloned from callee template
; IR. The template call sites keep their original ids, so every inlined copy must
; get a fresh id before it is attached to the root method.

@jeandle.personality = global ptr null

define hotspotcc i32 @root() #0 gc "hotspotgc" personality ptr @jeandle.personality {
entry:
  %OrigPcSlot = alloca i64, align 8
  %first = invoke hotspotcc i32 @callee_duplicate_statepoint_a() #2 [ "deopt"(i32 5, i32 5, i64 327695, ptr %OrigPcSlot) ]
          to label %after_first unwind label %root_unwind

after_first:
  %second = invoke hotspotcc i32 @callee_duplicate_statepoint_b() #2 [ "deopt"(i32 9, i32 9, i64 327695, ptr %OrigPcSlot) ]
          to label %exit unwind label %root_unwind

exit:
  %result = add i32 %first, %second
  ret i32 %result

root_unwind:
  %lpad = landingpad token
          cleanup
  ret i32 -1
}

declare hotspotcc i32 @callee_duplicate_statepoint_a() #1 gc "hotspotgc"
declare hotspotcc i32 @callee_duplicate_statepoint_b() #4 gc "hotspotgc"

attributes #0 = { "java-method"="6" }
attributes #1 = { "java-method"="108" }
attributes #2 = { "monomorphic-target" }
attributes #4 = { "java-method"="109" }

!java-method-compilation = !{}

; CHECK-LABEL: define hotspotcc i32 @root(
; CHECK: invoke hotspotcc void @leaf_with_duplicate_statepoint() #[[FIRST_ATTR:[0-9]+]]
; CHECK: invoke hotspotcc void @leaf_with_duplicate_statepoint() #[[SECOND_ATTR:[0-9]+]]
; CHECK-DAG: attributes #[[FIRST_ATTR]] = { {{.*}}"statepoint-id"="1007"{{.*}} }
; CHECK-DAG: attributes #[[SECOND_ATTR]] = { {{.*}}"statepoint-id"="1008"{{.*}} }
