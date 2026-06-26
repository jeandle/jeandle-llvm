; RUN: opt -S -passes="cha-devirtualization" -jeandle-vm-callback-log=%S/Inputs/virtual-call.cblog %s 2>&1 | FileCheck %s

; A virtual call with a unique CHA target is guarded by a receiver checkcast,
; rewritten to the concrete target, and marked as monomorphic.
; Non-Java invokes without a bytecode attribute are ignored.

@jeandle.personality = global ptr null

declare hotspotcc i1 @jeandle.check_instanceof(ptr, ptr addrspace(1))
declare hotspotcc ptr addrspace(1) @jeandle.new_array(i32) gc "hotspotgc"
declare hotspotcc i32 @Virtual_target(ptr addrspace(1)) #1 gc "hotspotgc"

define hotspotcc i32 @caller(ptr addrspace(1) "java-klass"="500" %recv) #0 gc "hotspotgc" personality ptr @jeandle.personality {
entry:
  %array = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(i32 1) [ "deopt"(i32 0, i32 0) ]
          to label %after_alloc unwind label %unwind

after_alloc:
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
; CHECK: invoke hotspotcc ptr addrspace(1) @jeandle.new_array(i32 1)
; CHECK: call hotspotcc i1 @jeandle.check_instanceof(ptr inttoptr (i64 600 to ptr), ptr addrspace(1) %recv)
; CHECK: br i1
; CHECK-LABEL: bci_cha_7_check_receiver_fail:
; CHECK: call hotspotcc i32 (...) @llvm.experimental.deoptimize.i32(i32 -201)
; CHECK: ret i32
; CHECK-LABEL: bci_cha_7_check_receiver_pass:
; CHECK: invoke hotspotcc i32 @Optimized_target(ptr addrspace(1) %recv) #[[CALLATTR:[0-9]+]]
; CHECK-SAME: [ "deopt"(
; CHECK: declare hotspotcc i32 @Optimized_target(ptr addrspace(1)) #[[TARGETATTR:[0-9]+]] gc "hotspotgc"
; CHECK: attributes #[[TARGETATTR]] = { "java-method"="700" }
; CHECK: attributes #[[CALLATTR]] = { {{.*}}"monomorphic-target"{{.*}}"statepoint-num-patch-bytes"="5"{{.*}} }

attributes #0 = { "java-method"="100" }
attributes #1 = { "java-method"="200" }
attributes #2 = { "bytecode"="invokevirtual" "call-site"="900" "declared-holder"="300" "statepoint-id"="42" "statepoint-num-patch-bytes"="15" }

!java-method-compilation = !{}
!static-call-patch-size = !{!0}

!0 = !{i32 5}
