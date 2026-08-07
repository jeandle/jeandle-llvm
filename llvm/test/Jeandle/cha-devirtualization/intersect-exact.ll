; RUN: opt -S -passes="cha-devirtualization" -jeandle-vm-callback-log=%S/Inputs/intersect-exact.cblog %s 2>&1 | FileCheck %s

; Regression test for typeIntersect dropping Exact on an equal-klass intersection.
;
; %recv has the base type {klass 500, Exact=false} from the "java-klass" parameter
; attribute (no "java-klass-exact"). A dominating check_instanceof(500, %recv)
; sharpens it to {500, Exact=true} because klass 500 is effectively final.
; typeIntersect({500,false}, {500,true}) must yield {500,true}.
;
; With the bug it yields {500,false}, so CHA forwards Exact=false to GetCHAOptInfo
; (replay returns no target) and the invoke stays virtual. With the fix, Exact=true
; propagates and CHA devirtualizes the invoke.

@jeandle.personality = global ptr null

declare hotspotcc i1 @jeandle.check_instanceof(ptr, ptr addrspace(1))
declare hotspotcc i32 @Virtual_target(ptr addrspace(1)) #1 gc "hotspotgc"

define hotspotcc i32 @caller(ptr addrspace(1) "java-klass"="500" %recv) #0 gc "hotspotgc" personality ptr @jeandle.personality {
entry:
  %ck = call hotspotcc i1 @jeandle.check_instanceof(ptr inttoptr (i64 500 to ptr), ptr addrspace(1) %recv)
  br i1 %ck, label %do_call, label %no_call

do_call:
  %ret = invoke hotspotcc i32 @Virtual_target(ptr addrspace(1) %recv) #2 [ "deopt"(i64 0, i32 7, i32 7) ]
          to label %normal unwind label %unwind

no_call:
  ret i32 -2

normal:
  ret i32 %ret

unwind:
  %lp = landingpad i64
          cleanup
  ret i32 -1
}

; Devirtualization happens only when Exact=true is propagated through typeIntersect.
; CHECK-LABEL: define hotspotcc i32 @caller(
; CHECK: call hotspotcc i1 @jeandle.check_instanceof(ptr inttoptr (i64 600 to ptr), ptr addrspace(1) %recv)
; CHECK: invoke hotspotcc i32 @Optimized_target(ptr addrspace(1) noundef %recv)
; CHECK: "monomorphic-target"

attributes #0 = { "java-method"="100" }
attributes #1 = { "java-method"="200" }
attributes #2 = { "bytecode"="invokevirtual" "call-site"="900" "declared-holder"="300" "statepoint-id"="42" "statepoint-num-patch-bytes"="15" }

!java-method-compilation = !{}
!static-call-patch-size = !{!0}

!0 = !{i32 5}
