; RUN: opt -disable-output -passes="require<partial-escape-analysis>" \
; RUN:   -jeandle-trace-pea %s 2>&1 | FileCheck %s --check-prefix=ATTR
; RUN: opt -disable-output -passes="require<partial-escape-analysis>" \
; RUN:   -jeandle-trace-pea \
; RUN:   '-jeandle-pea-analyze-function=filter.Target.work()V' \
; RUN:   '-jeandle-pea-analyze-function=filter.Target.work()V.extra' \
; RUN:   %s 2>&1 | FileCheck %s --check-prefix=ANALYZE-EXACT \
; RUN:     --implicit-check-not='function=@"filter.Target.work()V.extra.decoy"'
; RUN: opt -disable-output -passes="require<partial-escape-analysis>" \
; RUN:   -jeandle-trace-pea -jeandle-pea-analyze-only=.extra \
; RUN:   '-jeandle-pea-analyze-function=filter.Target.work()V' \
; RUN:   '-jeandle-pea-analyze-function=filter.Target.work()V.extra' \
; RUN:   %s 2>&1 | FileCheck %s --check-prefix=ANALYZE-AND \
; RUN:     --implicit-check-not='function=@"filter.Target.work()V"' \
; RUN:     --implicit-check-not='function=@"filter.Target.work()V.extra.decoy"'
; RUN: opt -disable-output -passes="require<partial-escape-analysis>" \
; RUN:   -jeandle-trace-pea -jeandle-pea-analyze-only=extra.decoy \
; RUN:   %s 2>&1 | FileCheck %s --check-prefix=ANALYZE-LEGACY \
; RUN:     --implicit-check-not='function=@"filter.Target.work()V"' \
; RUN:     --implicit-check-not='function=@"filter.Target.work()V.extra"'
; RUN: opt -disable-output -passes="partial-escape-iterative" \
; RUN:   -jeandle-pea-iterations=1 \
; RUN:   '-jeandle-dump-pea-ir-function=filter.Target.work()V' \
; RUN:   '-jeandle-dump-pea-ir-function=filter.Target.work()V.extra' \
; RUN:   %s 2>&1 | FileCheck %s --check-prefix=DUMP-EXACT \
; RUN:     --implicit-check-not='PEA-DUMP before iter=0 function filter.Target.work()V.extra.decoy' \
; RUN:     --implicit-check-not='PEA-SUMMARY function filter.Target.work()V.extra.decoy'
; RUN: opt -disable-output -passes="partial-escape-iterative" \
; RUN:   -jeandle-pea-iterations=1 %s 2>&1 | not grep 'PEA-SUMMARY'
; RUN: opt -disable-output -passes="partial-escape-iterative" \
; RUN:   -jeandle-pea-iterations=1 -jeandle-dump-pea-ir=.extra \
; RUN:   '-jeandle-dump-pea-ir-function=filter.Target.work()V' \
; RUN:   '-jeandle-dump-pea-ir-function=filter.Target.work()V.extra' \
; RUN:   %s 2>&1 | FileCheck %s --check-prefix=DUMP-AND \
; RUN:     --implicit-check-not='PEA-DUMP before iter=0 function filter.Target.work()V{{$}}' \
; RUN:     --implicit-check-not='PEA-DUMP before iter=0 function filter.Target.work()V.extra.decoy'
; RUN: opt -disable-output -passes="partial-escape-iterative" \
; RUN:   -jeandle-pea-iterations=1 -jeandle-dump-pea-ir=extra.decoy \
; RUN:   %s 2>&1 | FileCheck %s --check-prefix=DUMP-LEGACY \
; RUN:     --implicit-check-not='PEA-DUMP before iter=0 function filter.Target.work()V{{$}}' \
; RUN:     --implicit-check-not='PEA-DUMP before iter=0 function filter.Target.work()V.extra{{$}}'

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare i32 @__gxx_personality_v0(...)

define void @"filter.Target.work()V"() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %obj = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 1 to ptr), i32 16, i1 false)
          to label %normal unwind label %unwind

normal:
  ret void

unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

define void @"filter.Target.work()V.extra"() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %obj = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 2 to ptr), i32 16, i1 false)
          to label %normal unwind label %unwind

normal:
  ret void

unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

define void @"filter.Target.work()V.extra.decoy"() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %obj = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 3 to ptr), i32 16, i1 false)
          to label %normal unwind label %unwind

normal:
  ret void

unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; ATTR: PEA: EliminateAllocation function=@"filter.Target.work()V" [VO=0]
; ATTR: PEA: EliminateAllocation function=@"filter.Target.work()V.extra" [VO=0]
; ATTR: PEA: EliminateAllocation function=@"filter.Target.work()V.extra.decoy" [VO=0]

; ANALYZE-EXACT: PEA: EliminateAllocation function=@"filter.Target.work()V" [VO=0]
; ANALYZE-EXACT: PEA: EliminateAllocation function=@"filter.Target.work()V.extra" [VO=0]

; ANALYZE-AND: PEA: EliminateAllocation function=@"filter.Target.work()V.extra" [VO=0]

; ANALYZE-LEGACY: PEA: EliminateAllocation function=@"filter.Target.work()V.extra.decoy" [VO=0]

; DUMP-EXACT: ;; PEA-DUMP before iter=0 function filter.Target.work()V{{$}}
; DUMP-EXACT: ;; PEA-SUMMARY function filter.Target.work()V rounds=1 stop=iteration-cap
; DUMP-EXACT-NOT: ;; PEA-SUMMARY function filter.Target.work()V rounds=
; DUMP-EXACT: ;; PEA-DUMP before iter=0 function filter.Target.work()V.extra{{$}}
; DUMP-EXACT: ;; PEA-SUMMARY function filter.Target.work()V.extra rounds=1 stop=iteration-cap
; DUMP-EXACT-NOT: ;; PEA-SUMMARY

; DUMP-AND: ;; PEA-DUMP before iter=0 function filter.Target.work()V.extra{{$}}

; DUMP-LEGACY: ;; PEA-DUMP before iter=0 function filter.Target.work()V.extra.decoy{{$}}

!java-method-compilation = !{}
