; RUN: opt -S -passes="function(profile-devirtualization)" -jeandle-vm-callback-log=%S/Inputs/count-exceeds-total.cblog %s | FileCheck %s
; RUN: opt -S -passes="function(profile-devirtualization)" -jeandle-vm-callback-log=%S/Inputs/bimorphic-zero-second-count.cblog %s | FileCheck %s
; RUN: opt -S -passes="function(profile-devirtualization)" -jeandle-vm-callback-log=%S/Inputs/bimorphic-counts-exceed-total.cblog %s | FileCheck %s
; RUN: opt -S -passes="function(profile-devirtualization)" -jeandle-vm-callback-log=%S/Inputs/update-static-call-fails.cblog %s | FileCheck %s

; Invalid profile tuples and a failed metadata update must leave the virtual
; call unchanged.

@jeandle.personality = global ptr null

declare hotspotcc i32 @Virtual_target(ptr addrspace(1)) #1 gc "hotspotgc"

define hotspotcc i32 @caller(ptr addrspace(1) %recv) #0 gc "hotspotgc" personality ptr @jeandle.personality {
entry:
  %ret = invoke hotspotcc i32 @Virtual_target(ptr addrspace(1) %recv) #2 [ "deopt"(i64 0, i32 7, i32 7) ]
          to label %normal unwind label %unwind

normal:
  ret i32 %ret

unwind:
  %lp = landingpad i64
          cleanup
  ret i32 -1
}

; CHECK-LABEL: define hotspotcc i32 @caller(
; CHECK: invoke hotspotcc i32 @Virtual_target(
; CHECK-NOT: Profiled_target

attributes #0 = { "java-method"="100" }
attributes #1 = { "java-method"="200" }
attributes #2 = { "bytecode"="invokevirtual" "declared-holder"="300" "statepoint-id"="42" "statepoint-num-patch-bytes"="15" }

!java-method-compilation = !{}
!static-call-patch-size = !{!0}

!0 = !{i32 5}
