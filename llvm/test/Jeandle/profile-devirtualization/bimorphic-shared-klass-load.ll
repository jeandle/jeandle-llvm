; RUN: opt -S -passes="function(profile-devirtualization)" -jeandle-vm-callback-log=%S/Inputs/bimorphic-shared-klass-load.cblog %s 2>&1 | FileCheck %s
; RUN: opt -S -passes="function(profile-devirtualization),java-operation-lower<phase=0>,java-operation-lower<phase=1>" -jeandle-vm-callback-log=%S/Inputs/bimorphic-shared-klass-load.cblog %s 2>&1 | FileCheck %s --check-prefix=LOWER

; A bimorphic receiver guard loads the receiver Klass once and shares it
; between both exact-class checks. JavaType traces the shared load back to the
; receiver and sharpens it independently on either successful edge.

@jeandle.personality = global ptr null

define hotspotcc ptr addrspace(0) @jeandle.load_klass(ptr addrspace(1) %oop) #3 {
entry:
  %actual = load atomic ptr addrspace(0), ptr addrspace(1) %oop unordered, align 8
  ret ptr addrspace(0) %actual
}

define hotspotcc i1 @jeandle.check_exact_klass(ptr addrspace(0) %expected, ptr addrspace(0) %actual) #4 {
entry:
  %matches = icmp eq ptr addrspace(0) %actual, %expected
  ret i1 %matches
}

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
; CHECK: [[ACTUAL:%.*]] = call hotspotcc ptr @jeandle.load_klass(ptr addrspace(1) %recv)
; CHECK: call hotspotcc i1 @jeandle.check_exact_klass(ptr inttoptr (i64 600 to ptr), ptr [[ACTUAL]])
; CHECK-NOT: call hotspotcc ptr @jeandle.load_klass
; CHECK-LABEL: bci_profile_devirt_7_exact_receiver_1_check:
; CHECK-NOT: call hotspotcc ptr @jeandle.load_klass
; CHECK: call hotspotcc i1 @jeandle.check_exact_klass(ptr inttoptr (i64 601 to ptr), ptr [[ACTUAL]])
; CHECK-LABEL: bci_profile_devirt_7_exact_receiver_1_pass:
; CHECK: invoke hotspotcc i32 @Profiled_target_1(
; CHECK-LABEL: bci_profile_devirt_7_exact_receiver_fail:
; CHECK: call hotspotcc i32 {{.*}}@llvm.experimental.deoptimize.i32(
; CHECK-LABEL: bci_profile_devirt_7_exact_receiver_0_pass:
; CHECK: invoke hotspotcc i32 @Profiled_target_0(
; CHECK: declare hotspotcc i32 @Profiled_target_1(ptr addrspace(1)) #[[ACCESSOR:[0-9]+]]
; CHECK: attributes #[[ACCESSOR:[0-9]+]] = { {{.*}}"java-accessor-method"{{.*}} }

; LOWER-LABEL: define hotspotcc i32 @caller(
; LOWER: [[LOWERED_ACTUAL:%.*]] = load atomic ptr, ptr addrspace(1) %recv unordered, align 8
; LOWER-NOT: load atomic ptr
; LOWER: icmp eq ptr [[LOWERED_ACTUAL]], inttoptr (i64 600 to ptr)
; LOWER-NOT: load atomic ptr
; LOWER-LABEL: bci_profile_devirt_7_exact_receiver_1_check:
; LOWER-NOT: load atomic ptr
; LOWER: icmp eq ptr [[LOWERED_ACTUAL]], inttoptr (i64 601 to ptr)

attributes #0 = { "java-method"="100" }
attributes #1 = { "java-method"="200" }
attributes #2 = { "bytecode"="invokevirtual" "call-site"="900" "call-stub"="virtual_call" "declared-holder"="300" "statepoint-id"="42" "statepoint-num-patch-bytes"="15" }
attributes #3 = { noinline "lower-phase"="1" }
attributes #4 = { noinline "lower-phase"="1" }

!java-method-compilation = !{}
!static-call-patch-size = !{!0}

!0 = !{i32 5}
