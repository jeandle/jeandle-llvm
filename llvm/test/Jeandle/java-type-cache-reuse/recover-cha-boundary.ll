; RUN: opt -S -jeandle-java-type-stats -jeandle-java-type-query-trace -passes="recover-type-info,jeandle-java-type-cache-boundary,cha-devirtualization,print<java-type-analysis>" -jeandle-vm-callback-log=%S/Inputs/recover-cha.cblog %s 2>&1 | FileCheck %s
;
; X05: RecoverTypeInfo writes !java-klass and drops JavaTypeAnalysis. CHA must
; start from a new analysis that reads the newly emitted metadata; this is a
; lifecycle boundary, not a hit on RecoverTypeInfo's old cache.

@jeandle.personality = global ptr null

declare hotspotcc i1 @jeandle.check_instanceof(ptr, ptr addrspace(1))
declare hotspotcc i32 @Virtual_target(ptr addrspace(1)) #1 gc "hotspotgc"

define hotspotcc i32 @recover_cha(ptr addrspace(1) "java-klass"="5" %obj) #0 gc "hotspotgc" personality ptr @jeandle.personality {
entry:
  %p = getelementptr i8, ptr addrspace(1) %obj, i64 16
  %field = load ptr addrspace(1), ptr addrspace(1) %p, align 8
  %ret = invoke hotspotcc i32 @Virtual_target(ptr addrspace(1) %field) #2 [ "deopt"(i64 0, i32 7, i32 7) ]
          to label %normal unwind label %unwind

normal:
  ret i32 %ret

unwind:
  %lp = landingpad i64
          cleanup
  ret i32 -1
}

; CHECK: JavaTypeCacheBoundary function: recover_cha existing_analysis=0 action=none
; CHECK: JavaTypeQuery function: recover_cha ordinal:
; CHECK: JavaTypeAnalysis for function: recover_cha
; CHECK:         queries: 2
; CHECK:         final type hits: 0
; CHECK:         final type misses: 2
; CHECK:         base insertions: 2
; CHECK:         clears: 0
; CHECK:         invalidation requests: 1
; CHECK:         CFG invalidations: 1
; CHECK: invoke hotspotcc i32 @Optimized_target
; CHECK: "monomorphic-target"

attributes #0 = { "java-method"="100" }
attributes #1 = { "java-method"="200" }
attributes #2 = { "bytecode"="invokevirtual" "call-site"="900" "declared-holder"="300" "statepoint-id"="42" "statepoint-num-patch-bytes"="15" }

!java-method-compilation = !{}
!static-call-patch-size = !{!0}

!0 = !{i32 5}
