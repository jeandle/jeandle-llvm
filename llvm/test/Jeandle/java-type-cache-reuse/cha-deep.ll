; RUN: opt -S -jeandle-java-type-stats -passes="cha-devirtualization,print<java-type-analysis>" -jeandle-vm-callback-log=%S/Inputs/cha-reuse.cblog %s 2>&1 | FileCheck %s
;
; T04 deep CFG pair: the same four call sites and receiver are serialized so
; each call sits in a deeper context block. Query counts stay equal to the
; shallow case; the difference is CFG depth and repeated block splitting.

@jeandle.personality = global ptr null

declare hotspotcc i1 @jeandle.check_instanceof(ptr, ptr addrspace(1))
declare hotspotcc i32 @Virtual_target(ptr addrspace(1)) #1 gc "hotspotgc"

define hotspotcc i32 @caller.root(ptr addrspace(1) "java-klass"="500" %recv) #0 gc "hotspotgc" personality ptr @jeandle.personality {
entry:
  %r0 = invoke hotspotcc i32 @Virtual_target(ptr addrspace(1) %recv) #2 [ "deopt"(i64 0, i32 7, i32 7) ]
          to label %n0 unwind label %unwind
n0:
  %r1 = invoke hotspotcc i32 @Virtual_target(ptr addrspace(1) %recv) #3 [ "deopt"(i64 0, i32 7, i32 7) ]
          to label %n1 unwind label %unwind
n1:
  %r2 = invoke hotspotcc i32 @Virtual_target(ptr addrspace(1) %recv) #4 [ "deopt"(i64 0, i32 7, i32 7) ]
          to label %n2 unwind label %unwind
n2:
  %r3 = invoke hotspotcc i32 @Virtual_target(ptr addrspace(1) %recv) #5 [ "deopt"(i64 0, i32 7, i32 7) ]
          to label %n3 unwind label %unwind
n3:
  ret i32 0
unwind:
  %lp = landingpad i64
          cleanup
  ret i32 -1
}

; CHECK-LABEL: JavaTypeAnalysis for function: caller.root
; CHECK:         queries: 4
; CHECK:         final type hits: 0
; CHECK:         final type misses: 4
; CHECK:         base insertions: 1
; CHECK:         invalidation requests: 4
; CHECK:         CFG invalidations: 4
; CHECK:         base entries invalidated: 0
; CHECK:         final type entries invalidated: 4
; CHECK-COUNT-4: invoke hotspotcc i32 @caller

attributes #0 = { "java-method"="100" }
attributes #1 = { "java-method"="200" }
attributes #2 = { "bytecode"="invokevirtual" "call-site"="900" "declared-holder"="300" "statepoint-id"="42" "statepoint-num-patch-bytes"="15" }
attributes #3 = { "bytecode"="invokevirtual" "call-site"="901" "declared-holder"="300" "statepoint-id"="43" "statepoint-num-patch-bytes"="15" }
attributes #4 = { "bytecode"="invokevirtual" "call-site"="902" "declared-holder"="300" "statepoint-id"="44" "statepoint-num-patch-bytes"="15" }
attributes #5 = { "bytecode"="invokevirtual" "call-site"="903" "declared-holder"="300" "statepoint-id"="45" "statepoint-num-patch-bytes"="15" }

!java-method-compilation = !{}
!static-call-patch-size = !{!0}

!0 = !{i32 5}
