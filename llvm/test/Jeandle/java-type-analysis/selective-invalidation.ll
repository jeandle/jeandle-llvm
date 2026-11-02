; RUN: opt -disable-output -verify-each -jeandle-java-type-stats -passes='function(type-check-elimination,cha-devirtualization),print<java-type-analysis-summary>' -jeandle-vm-callback-log=%S/Inputs/selective-invalidation.cblog %s 2>&1 | FileCheck %s --check-prefix=SELECTIVE
; RUN: opt -disable-output -verify-each -jeandle-java-type-force-full-invalidation -jeandle-java-type-stats -passes='function(type-check-elimination,cha-devirtualization),print<java-type-analysis-summary>' -jeandle-vm-callback-log=%S/Inputs/selective-invalidation.cblog %s 2>&1 | FileCheck %s --check-prefix=FULL
; RUN: opt -S -verify-each -jeandle-verify-java-type-cache -jeandle-java-type-stats -passes='function(type-check-elimination,cha-devirtualization),print<java-type-analysis-summary>' -jeandle-vm-callback-log=%S/Inputs/selective-invalidation.cblog %s 2>&1 | FileCheck %s --check-prefix=VERIFY
;
; TCE folds the check, then CHA resolves two static MethodHandle calls using
; the same select DAG. Only the old calls and their users change; the four
; base entries survive all five notifications. Each pass updates its FAM
; dependencies before preserving JavaTypeAnalysis.
;
; SELECTIVE: queries: 3
; SELECTIVE: base insertions: 4
; SELECTIVE: clears: 0
; SELECTIVE: invalidation requests: 5
; SELECTIVE: selective invalidations: 5
; SELECTIVE: CFG invalidations: 0
; SELECTIVE: base entries invalidated: 0
; SELECTIVE: base entries retained: 20
;
; FULL: queries: 3
; FULL: base insertions: 12
; FULL: clears: 5
; FULL: selective invalidations: 0
; FULL: base entries retained: 0
;
; VERIFY: verifications: 3
; VERIFY-LABEL: define hotspotcc ptr addrspace(1) @caller0(
; VERIFY-NOT: call hotspotcc i1 @jeandle.check_instanceof
; VERIFY: invoke hotspotcc ptr addrspace(1) @Optimized_target
; VERIFY: invoke hotspotcc ptr addrspace(1) @Optimized_target

@jeandle.personality = global ptr null
@oop_handle_member_5 = external global ptr addrspace(1)
declare hotspotcc i1 @jeandle.check_instanceof(ptr, ptr addrspace(1) nonnull)
declare hotspotcc ptr addrspace(1) @link(ptr addrspace(1), ptr addrspace(1)) #1 gc "hotspotgc"
declare hotspotcc ptr addrspace(1) @virtual(ptr addrspace(1)) #1 gc "hotspotgc"
define hotspotcc ptr addrspace(1) @caller0(ptr addrspace(1) "java-klass"="22" %a, ptr addrspace(1) "java-klass"="22" %b, i1 %c) #0 gc "hotspotgc" personality ptr @jeandle.personality {
entry:
  %member = load ptr addrspace(1), ptr @oop_handle_member_5
  %s0 = select i1 %c, ptr addrspace(1) %a, ptr addrspace(1) %b
  %s1 = select i1 %c, ptr addrspace(1) %s0, ptr addrspace(1) %b
  %check = call hotspotcc i1 @jeandle.check_instanceof(ptr inttoptr (i64 22 to ptr), ptr addrspace(1) nonnull %s1)
  %r0 = invoke hotspotcc ptr addrspace(1) @link(ptr addrspace(1) %s1, ptr addrspace(1) %member) #2 [ "deopt"(i64 0, i32 7, i32 7) ] to label %next0 unwind label %unwind
next0:
  %r1 = invoke hotspotcc ptr addrspace(1) @link(ptr addrspace(1) %s1, ptr addrspace(1) %member) #3 [ "deopt"(i64 0, i32 7, i32 7) ] to label %next1 unwind label %unwind
next1:
  ret ptr addrspace(1) %r1
unwind:
  %lp = landingpad i64 cleanup
  ret ptr addrspace(1) null
}
attributes #0 = { "java-method"="100" }
attributes #1 = { "java-method"="200" }
attributes #2 = { "bytecode"="invokehandle" "monomorphic-target" "mh-intrinsic-name"="_linkToStatic" "declared-holder"="300" "statepoint-id"="42" "statepoint-num-patch-bytes"="5" }
attributes #3 = { "bytecode"="invokehandle" "monomorphic-target" "mh-intrinsic-name"="_linkToStatic" "declared-holder"="300" "statepoint-id"="43" "statepoint-num-patch-bytes"="5" }
!java-method-compilation = !{}
!static-call-patch-size = !{!0}
!0 = !{i32 5}
