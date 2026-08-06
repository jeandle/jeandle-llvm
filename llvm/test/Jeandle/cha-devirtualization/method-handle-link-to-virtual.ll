; RUN: opt -S -passes="cha-devirtualization" -jeandle-vm-callback-log=%S/Inputs/method-handle-link-to-virtual.cblog %s 2>&1 | FileCheck %s

; This is distilled from test/cha_invokehandle/InlineTest.java:
; MethodHandle.invokeExact reaches the _linkToVirtual intrinsic with a constant
; MemberName oop. CHA first resolves that MethodHandle intrinsic to the
; interface method, then devirtualizes the resulting virtual call to D::m.

@jeandle.personality = global ptr null
@oop_handle_java.lang.invoke.MemberName_5 = external dso_local global ptr addrspace(1)

declare hotspotcc i1 @jeandle.check_instanceof(ptr, ptr addrspace(1))
declare hotspotcc ptr addrspace(1) @jeandle.assume_java_type(ptr addrspace(1))
declare hotspotcc ptr addrspace(1) @"java_lang_invoke_MethodHandle_linkToVirtual(Ljava/lang/Object;Ljava/lang/invoke/MemberName;)Ljava/lang/Object;"(ptr addrspace(1), ptr addrspace(1)) #1 gc "hotspotgc"

define hotspotcc ptr addrspace(1) @caller(ptr addrspace(1) "java-klass"="2148289576" %recv) #0 gc "hotspotgc" personality ptr @jeandle.personality {
entry:
  %member_name = load ptr addrspace(1), ptr @oop_handle_java.lang.invoke.MemberName_5, align 8
  %ret = invoke hotspotcc ptr addrspace(1) @"java_lang_invoke_MethodHandle_linkToVirtual(Ljava/lang/Object;Ljava/lang/invoke/MemberName;)Ljava/lang/Object;"(ptr addrspace(1) %recv, ptr addrspace(1) %member_name) #2 [ "deopt"(i64 0, i32 17, i32 17) ]
          to label %normal unwind label %unwind

normal:
  ret ptr addrspace(1) %ret

unwind:
  %lp = landingpad i64
          cleanup
  ret ptr addrspace(1) null
}

; CHECK-LABEL: define hotspotcc ptr addrspace(1) @caller(
; CHECK-NOT: @java_lang_invoke_MethodHandle_linkToVirtual
; CHECK: icmp eq
; CHECK: br i1
; CHECK-LABEL: null_check_bci_17_null_check_fail:
; CHECK: call hotspotcc ptr addrspace(1) (...) @llvm.experimental.deoptimize.p1(i32 -10)
; CHECK-LABEL: null_check_bci_17_null_check_pass:
; CHECK: call hotspotcc i1 @jeandle.check_instanceof
; CHECK: br i1
; CHECK-LABEL: cha_bci_17_check_receiver_fail:
; CHECK: call hotspotcc ptr addrspace(1) (...) @llvm.experimental.deoptimize.p1(i32 -201)
; CHECK: ret ptr addrspace(1)
; CHECK-LABEL: cha_bci_17_check_receiver_pass:
; CHECK: invoke hotspotcc ptr addrspace(1) @"InlineTest$D_m()Ljava/lang/Object;"(ptr addrspace(1) noundef %recv) #[[CALLATTR:[0-9]+]]
; CHECK-SAME: [ "deopt"(
; CHECK: declare hotspotcc ptr addrspace(1) @"InlineTest$D_m()Ljava/lang/Object;"(ptr addrspace(1)) #[[TARGETATTR:[0-9]+]] gc "hotspotgc"
; CHECK: attributes #[[TARGETATTR]] = { "java-method"="135644198486144" }
; CHECK: attributes #[[CALLATTR]] = { {{.*}}"bytecode"="invokevirtual"{{.*}}"declared-holder"="135644198485624"{{.*}}"monomorphic-target"{{.*}}"statepoint-num-patch-bytes"="5"{{.*}} }

attributes #0 = { "java-method"="135644197250128" }
attributes #1 = { "java-method"="135644198481896" }
attributes #2 = { "bytecode"="invokehandle" "monomorphic-target" "declared-holder"="135634798794696" "mh-intrinsic-name"="_linkToVirtual" "statepoint-id"="18" "statepoint-num-patch-bytes"="5" }

!java-method-compilation = !{}
!static-call-patch-size = !{!0}
!dynamic-call-patch-size = !{!1}

!0 = !{i32 5}
!1 = !{i32 15}
