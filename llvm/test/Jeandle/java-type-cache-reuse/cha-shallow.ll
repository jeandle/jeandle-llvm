; RUN: opt -S -jeandle-java-type-stats -jeandle-java-type-query-trace -passes="cha-devirtualization,print<java-type-analysis>" -jeandle-vm-callback-log=%S/Inputs/cha-reuse.cblog %s 2>&1 | FileCheck %s
;
; T04 shallow CFG: four sibling blocks invoke the same receiver. CHA rewrites
; every site and invalidates contextual results after each rewrite, so Final
; misses at all four sites while the independent Base entry survives.

@jeandle.personality = global ptr null

declare hotspotcc i1 @jeandle.check_instanceof(ptr, ptr addrspace(1))
declare hotspotcc i32 @Virtual_target(ptr addrspace(1)) #1 gc "hotspotgc"

define hotspotcc i32 @caller.root(ptr addrspace(1) "java-klass"="500" %recv,
                                  i32 %sel) #0 gc "hotspotgc" personality ptr @jeandle.personality {
entry:
  switch i32 %sel, label %join [ i32 0, label %b0
                                 i32 1, label %b1
                                 i32 2, label %b2
                                 i32 3, label %b3 ]
b0:
  %r0 = invoke hotspotcc i32 @Virtual_target(ptr addrspace(1) %recv) #2 [ "deopt"(i64 0, i32 7, i32 7) ]
          to label %n0 unwind label %unwind
n0:
  br label %join
b1:
  %r1 = invoke hotspotcc i32 @Virtual_target(ptr addrspace(1) %recv) #3 [ "deopt"(i64 0, i32 7, i32 7) ]
          to label %n1 unwind label %unwind
n1:
  br label %join
b2:
  %r2 = invoke hotspotcc i32 @Virtual_target(ptr addrspace(1) %recv) #4 [ "deopt"(i64 0, i32 7, i32 7) ]
          to label %n2 unwind label %unwind
n2:
  br label %join
b3:
  %r3 = invoke hotspotcc i32 @Virtual_target(ptr addrspace(1) %recv) #5 [ "deopt"(i64 0, i32 7, i32 7) ]
          to label %n3 unwind label %unwind
n3:
  br label %join
join:
  ret i32 0
unwind:
  %lp = landingpad i64
          cleanup
  ret i32 -1
}

; CHECK: JavaTypeQuery function: caller.root ordinal: 1
; CHECK-SAME: final_hits: 0 final_misses: 1 base_insertions: 1
; CHECK: JavaTypeQuery function: caller.root ordinal: 2
; CHECK-SAME: final_hits: 0 final_misses: 1 base_insertions: 0
; CHECK: JavaTypeQuery function: caller.root ordinal: 3
; CHECK-SAME: final_hits: 0 final_misses: 1 base_insertions: 0
; CHECK: JavaTypeQuery function: caller.root ordinal: 4
; CHECK-SAME: final_hits: 0 final_misses: 1 base_insertions: 0
; CHECK-LABEL: JavaTypeAnalysis for function: caller.root
; CHECK:         queries: 4
; CHECK:         final type hits: 0
; CHECK:         final type misses: 4
; CHECK:         base insertions: 1
; CHECK:         current base entries: 1
; CHECK:         current final type entries: 0
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
