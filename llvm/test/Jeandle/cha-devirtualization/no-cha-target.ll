; RUN: opt -S -passes="cha-devirtualization" -jeandle-vm-callback-log=%S/Inputs/no-cha-target.cblog %s 2>&1 | FileCheck %s

; If the VM reports no CHA target, the invoke must remain a virtual call.

@jeandle.personality = global ptr null

declare hotspotcc i1 @jeandle.checkcast(ptr, ptr addrspace(1))
declare hotspotcc i32 @Virtual_target(ptr addrspace(1)) #1 gc "hotspotgc"

define hotspotcc i32 @caller(ptr addrspace(1) "java-klass"="500" %recv) #0 gc "hotspotgc" personality ptr @jeandle.personality {
entry:
  %ret = invoke hotspotcc i32 @Virtual_target(ptr addrspace(1) %recv) #2 [ "deopt"(i32 7, i32 7) ]
          to label %normal unwind label %unwind

normal:
  ret i32 %ret

unwind:
  %lp = landingpad i64
          cleanup
  ret i32 -1
}

; CHECK-LABEL: define hotspotcc i32 @caller(
; CHECK-NOT: @jeandle.checkcast
; CHECK: invoke hotspotcc i32 @Virtual_target(ptr addrspace(1) %recv) #[[CALLATTR:[0-9]+]]
; CHECK: attributes #[[CALLATTR]] = { {{.*}}"bytecode"="invokevirtual"{{.*}}"statepoint-num-patch-bytes"="15"{{.*}} }
; CHECK-NOT: @Optimized_target

attributes #0 = { "java-method"="100" }
attributes #1 = { "java-method"="200" }
attributes #2 = { "bytecode"="invokevirtual" "call-site"="900" "declared-holder"="300" "statepoint-id"="43" "statepoint-num-patch-bytes"="15" }

!java-method-compilation = !{}
!static-call-patch-size = !{!0}

!0 = !{i32 5}
