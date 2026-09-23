; RUN: opt -S -passes="cha-devirtualization" -jeandle-vm-callback-log=%S/Inputs/method-handle-invoke-basic.cblog %s 2>&1 | FileCheck %s

; _invokeBasic is optimized in place when its MethodHandle receiver is a
; constant oop. The VM callback returns a tagged target holder, rather than
; the receiver constraint used by ordinary virtual calls.

@jeandle.personality = global ptr null
@oop_handle_java.lang.invoke.MethodHandle_5 = external dso_local global ptr addrspace(1)

declare hotspotcc ptr addrspace(1) @"java_lang_invoke_MethodHandle_invokeBasic(Ljava/lang/Object;)Ljava/lang/Object;"(ptr addrspace(1), ptr addrspace(1)) #1 gc "hotspotgc"

define hotspotcc ptr addrspace(1) @caller(ptr addrspace(1) %arg) #0 gc "hotspotgc" personality ptr @jeandle.personality {
entry:
  %method_handle = load ptr addrspace(1), ptr @oop_handle_java.lang.invoke.MethodHandle_5, align 8
  %ret = invoke hotspotcc ptr addrspace(1) @"java_lang_invoke_MethodHandle_invokeBasic(Ljava/lang/Object;)Ljava/lang/Object;"(ptr addrspace(1) %method_handle, ptr addrspace(1) %arg) #2 [ "deopt"(i64 0, i32 17, i32 17) ]
          to label %normal unwind label %unwind

normal:
  ret ptr addrspace(1) %ret

unwind:
  %lp = landingpad i64
          cleanup
  ret ptr addrspace(1) null
}

; CHECK-LABEL: define hotspotcc ptr addrspace(1) @caller(
; CHECK: invoke hotspotcc ptr addrspace(1) @"Target_invoke(Ljava/lang/invoke/MethodHandle;Ljava/lang/Object;)Ljava/lang/Object;"(ptr addrspace(1) noundef %method_handle, ptr addrspace(1) %arg) #[[CALLATTR:[0-9]+]]
; CHECK-SAME: [ "deopt"(
; CHECK: declare hotspotcc ptr addrspace(1) @"Target_invoke(Ljava/lang/invoke/MethodHandle;Ljava/lang/Object;)Ljava/lang/Object;"(ptr addrspace(1), ptr addrspace(1)) #[[TARGETATTR:[0-9]+]] gc "hotspotgc"
; CHECK: attributes #[[TARGETATTR]] = { "java-method"="500" }
; CHECK: attributes #[[CALLATTR]] = { {{.*}}"monomorphic-target"{{.*}}"statepoint-num-patch-bytes"="5"{{.*}} }

attributes #0 = { "java-method"="100" }
attributes #1 = { "java-method"="200" }
attributes #2 = { "bytecode"="invokehandle" "monomorphic-target" "declared-holder"="300" "mh-intrinsic-name"="_invokeBasic" "statepoint-id"="18" "statepoint-num-patch-bytes"="5" }

!java-method-compilation = !{}
!static-call-patch-size = !{!0}
!dynamic-call-patch-size = !{!1}

!0 = !{i32 5}
!1 = !{i32 15}
