; RUN: opt -S -passes="function(profile-devirtualization)" -jeandle-vm-callback-log=%S/Inputs/monomorphic-virtual-miss.cblog %s 2>&1 | FileCheck %s
; RUN: opt -S -passes="function(profile-devirtualization),function(profile-devirtualization)" -jeandle-enable-profile-devirt-inline=false -jeandle-vm-callback-log=%S/Inputs/monomorphic-virtual-miss.cblog %s 2>&1 | FileCheck %s

; A mature monomorphic profile with prior traps keeps a guarded direct-call
; fast path, but falls back to the original virtual invoke instead of
; deoptimizing again. The cloned fallback gets a fresh statepoint id and is
; marked so later profile-devirtualization rounds leave it virtual. The target
; name contains the protocol separator to exercise length-prefixed decoding.

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
  ; Root scope followed by a current-layout inlinee scope. Profile lookup must
  ; use method 400 from the innermost scope, not root method 100.
  %ret = invoke hotspotcc i32 @Virtual_target(ptr addrspace(1) %recv) #2 [ "deopt"(i64 0, i32 0, i32 0, i64 393233, i64 400, i64 0, i32 7, i32 7) ]
          to label %normal unwind label %unwind

normal:
  ret i32 %ret

unwind:
  %lp = landingpad i64
          cleanup
  ret i32 -1
}

; CHECK-LABEL: define hotspotcc i32 @caller(
; CHECK: call hotspotcc ptr @jeandle.load_klass(ptr addrspace(1) %recv)
; CHECK: call hotspotcc i1 @jeandle.check_exact_klass(ptr inttoptr (i64 600 to ptr)
; CHECK: br i1 {{.*}}, label %bci_profile_devirt_7_exact_receiver_pass, label %bci_profile_devirt_7_exact_receiver_fail, !prof
; CHECK-LABEL: bci_profile_devirt_7_exact_receiver_fail:
; CHECK: invoke hotspotcc i32 @Virtual_target(
; CHECK-LABEL: bci_profile_devirt_7_exact_receiver_pass:
; CHECK: invoke hotspotcc i32 @"Profiled#target_0"(
; CHECK-LABEL: ret.profile.devirt.join:
; CHECK: phi i32
; CHECK: declare hotspotcc i32 @"Profiled#target_0"(ptr addrspace(1)) #[[ACCESSOR:[0-9]+]]
; CHECK: attributes #[[ACCESSOR:[0-9]+]] = { {{.*}}"java-accessor-method"{{.*}} }

attributes #0 = { "java-method"="100" }
attributes #1 = { "java-method"="200" }
attributes #2 = { "bytecode"="invokevirtual" "declared-holder"="300" "statepoint-id"="42" "statepoint-num-patch-bytes"="15" }
attributes #3 = { noinline "lower-phase"="1" }
attributes #4 = { noinline "lower-phase"="1" }

!java-method-compilation = !{}
!static-call-patch-size = !{!0}

!0 = !{i32 5}
