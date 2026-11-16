; RUN: opt -S -jeandle-java-type-stats -passes="cha-devirtualization,print<java-type-analysis>" -jeandle-vm-callback-log=%S/Inputs/two-pass.cblog %s 2>&1 | FileCheck %s

; Two-pass read/write separation: the method-handle site and the following
; virtual site are both analyzed before either is rewritten. The virtual site
; therefore sees the unmodified IR and shares the receiver's base type entry;
; the rebuilt method-handle invoke is refined by CHA in the next epoch.

@jeandle.personality = global ptr null
@oop_handle_java.lang.invoke.MemberName_5 = external dso_local global ptr addrspace(1)

declare hotspotcc i1 @jeandle.check_instanceof(ptr, ptr addrspace(1))
declare hotspotcc ptr addrspace(1) @"java_lang_invoke_MethodHandle_linkToVirtual(Ljava/lang/Object;Ljava/lang/invoke/MemberName;)Ljava/lang/Object;"(ptr addrspace(1), ptr addrspace(1)) #1 gc "hotspotgc"
declare hotspotcc ptr addrspace(1) @Virtual_target(ptr addrspace(1)) #4 gc "hotspotgc"

define hotspotcc i32 @caller(ptr addrspace(1) "java-klass"="2148289576" %recv) #0 gc "hotspotgc" personality ptr @jeandle.personality {
entry:
  %member_name = load ptr addrspace(1), ptr @oop_handle_java.lang.invoke.MemberName_5, align 8
  %ret = invoke hotspotcc ptr addrspace(1) @"java_lang_invoke_MethodHandle_linkToVirtual(Ljava/lang/Object;Ljava/lang/invoke/MemberName;)Ljava/lang/Object;"(ptr addrspace(1) %recv, ptr addrspace(1) %member_name) #2 [ "deopt"(i64 0, i32 17, i32 17) ]
          to label %normal unwind label %unwind

normal:
  %ret2 = invoke hotspotcc ptr addrspace(1) @Virtual_target(ptr addrspace(1) %recv) #3 [ "deopt"(i64 0, i32 19, i32 19) ]
          to label %done unwind label %unwind

done:
  ret i32 0

unwind:
  %lp = landingpad i64
          cleanup
  ret i32 -1
}

; Both epoch-one queries run before any rewrite, so their contextual results
; coexist: two peak final-type entries. A query-per-rewrite implementation
; (one pass) never holds more than one and reports 1.
; CHECK-LABEL: JavaTypeAnalysis for function: caller
; CHECK:         queries: 3
; CHECK:         base query hits: 2
; CHECK:         base insertions: 1
; CHECK:         peak final type entries: 2
; CHECK:         invalidation requests: 4
; CHECK:         CFG invalidations: 3

; The intrinsic is gone and both sites end up in the same CHA target.
; CHECK-LABEL: define hotspotcc i32 @caller(
; CHECK-NOT: @java_lang_invoke_MethodHandle_linkToVirtual
; CHECK-COUNT-2: invoke hotspotcc ptr addrspace(1) @"InlineTest$D_m()Ljava/lang/Object;"(ptr addrspace(1)

attributes #0 = { "java-method"="135644197250128" }
attributes #1 = { "java-method"="135644198481896" }
attributes #2 = { "bytecode"="invokehandle" "monomorphic-target" "declared-holder"="135634798794696" "mh-intrinsic-name"="_linkToVirtual" "statepoint-id"="18" "statepoint-num-patch-bytes"="5" }
attributes #3 = { "bytecode"="invokevirtual" "call-site"="901" "declared-holder"="135644198485624" "statepoint-id"="19" "statepoint-num-patch-bytes"="15" }
attributes #4 = { "java-method"="135644198485800" }

!java-method-compilation = !{}
!static-call-patch-size = !{!0}
!dynamic-call-patch-size = !{!1}

!0 = !{i32 5}
!1 = !{i32 15}
