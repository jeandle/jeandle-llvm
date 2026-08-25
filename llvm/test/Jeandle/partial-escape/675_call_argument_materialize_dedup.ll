; RUN: opt -disable-output -verify-each \
; RUN:   -passes="require<partial-escape-analysis>" -jeandle-trace-pea \
; RUN:   -jeandle-pea-analyze-function=test_same_twice %s 2>&1 \
; RUN:   | FileCheck %s --check-prefix=TRACE-SAME \
; RUN:     --implicit-check-not='PEA: Materialize function=@test_same_twice'
; RUN: opt -disable-output -verify-each \
; RUN:   -passes="require<partial-escape-analysis>" -jeandle-trace-pea \
; RUN:   -jeandle-pea-analyze-function=test_two_objects %s 2>&1 \
; RUN:   | FileCheck %s --check-prefix=TRACE-TWO \
; RUN:     --implicit-check-not='PEA: Materialize function=@test_two_objects'
; RUN: opt -disable-output -verify-each \
; RUN:   -passes="require<partial-escape-analysis>" -jeandle-trace-pea \
; RUN:   -jeandle-pea-analyze-function=test_nested_arguments %s 2>&1 \
; RUN:   | FileCheck %s --check-prefix=TRACE-NESTED \
; RUN:     --implicit-check-not='PEA: Materialize function=@test_nested_arguments'
; RUN: opt -disable-output -verify-each \
; RUN:   -passes="require<partial-escape-analysis>" -jeandle-trace-pea \
; RUN:   -jeandle-pea-analyze-function=test_call_or_not %s 2>&1 \
; RUN:   | FileCheck %s --check-prefix=TRACE-BRANCH \
; RUN:     --implicit-check-not='PEA: Materialize function=@test_call_or_not'
; RUN: opt -S -verify-each \
; RUN:   -passes="require<partial-escape-analysis>,partial-escape-transform" %s \
; RUN:   | FileCheck %s --check-prefix=FINAL

; A real call argument is materialized once per distinct ObjectID, not once
; per argument use. Nested virtual fields are materialized recursively before
; their owner, and the same recursion state deduplicates a child that is also
; a top-level actual argument. Since Jeandle reuses OrigAlloc, every replay is
; placed only on the call predecessor and no allocation is created there.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink2(ptr addrspace(1), ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @test_same_twice(i32 %value)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %obj = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
             ptr inttoptr (i64 10101 to ptr), i32 24, i1 false)
         to label %body unwind label %unwind
body:
  %field = getelementptr inbounds i8, ptr addrspace(1) %obj, i64 8
  store atomic i32 %value, ptr addrspace(1) %field unordered, align 4
  call void @sink2(ptr addrspace(1) %obj, ptr addrspace(1) %obj)
       [ "deopt"(i32 99, i32 99,
                   i64 12, ptr addrspace(1) %obj,
                   i64 4294967308, ptr addrspace(1) %obj) ]
  ret void
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; One ObjectID in two argument positions produces one top-level effect.
; TRACE-SAME: PEA: Materialize function=@test_same_twice [VO=0] block=%body

; FINAL-LABEL: define void @test_same_twice(
; FINAL: %obj = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; FINAL-NOT: invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; The source store is already the exact canonical suffix immediately before
; the escape, so structural replay recognition may reuse it without renaming
; its GEP.
; FINAL: %[[SAME_SLOT:[A-Za-z0-9._]+]] = getelementptr inbounds i8, ptr addrspace(1) %obj, i64 8
; FINAL-NEXT: store atomic i32 %value, ptr addrspace(1) %[[SAME_SLOT]] unordered, align 4
; Both positions and both deopt slots retain the one real identity.
; FINAL-NEXT: call void @sink2(ptr addrspace(1) %obj, ptr addrspace(1) %obj)
; FINAL-SAME: [ "deopt"(i32 99, i32 99, i64 12, ptr addrspace(1) %obj, i64 4294967308, ptr addrspace(1) %obj) ]
; FINAL-NOT: i64 262156
; FINAL-NOT: i64 524300
; FINAL-NOT: poison

define void @test_two_objects(i32 %left, i32 %right)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
           ptr inttoptr (i64 20201 to ptr), i32 24, i1 false)
       to label %alloc.b unwind label %unwind
alloc.b:
  %b = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
           ptr inttoptr (i64 20202 to ptr), i32 24, i1 false)
       to label %body unwind label %unwind
body:
  %af = getelementptr inbounds i8, ptr addrspace(1) %a, i64 8
  %bf = getelementptr inbounds i8, ptr addrspace(1) %b, i64 8
  store atomic i32 %left, ptr addrspace(1) %af unordered, align 4
  store atomic i32 %right, ptr addrspace(1) %bf unordered, align 4
  call void @sink2(ptr addrspace(1) %a, ptr addrspace(1) %b)
       [ "deopt"(i32 99, i32 99,
                   i64 12, ptr addrspace(1) %a,
                   i64 4294967308, ptr addrspace(1) %b) ]
  ret void
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; Each distinct ObjectID is a top-level materialization exactly once.
; TRACE-TWO: PEA: Materialize function=@test_two_objects [VO=0] block=%body
; TRACE-TWO: PEA: Materialize function=@test_two_objects [VO=1] block=%body

; FINAL-LABEL: define void @test_two_objects(
; FINAL: %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; FINAL: %b = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; FINAL-NOT: invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; FINAL: %[[A_SLOT:pea\.matslot[0-9]*]] = getelementptr inbounds i8, ptr addrspace(1) %a, i64 8
; FINAL-NEXT: store atomic i32 %left, ptr addrspace(1) %[[A_SLOT]] unordered, align 4
; FINAL-NEXT: %[[B_SLOT:pea\.matslot[0-9]*]] = getelementptr inbounds i8, ptr addrspace(1) %b, i64 8
; FINAL-NEXT: store atomic i32 %right, ptr addrspace(1) %[[B_SLOT]] unordered, align 4
; FINAL-NEXT: call void @sink2(ptr addrspace(1) %a, ptr addrspace(1) %b)
; FINAL-SAME: [ "deopt"(i32 99, i32 99, i64 12, ptr addrspace(1) %a, i64 4294967308, ptr addrspace(1) %b) ]
; Neither real actual receives a virtual-object descriptor.
; FINAL-NOT: i64 262156
; FINAL-NOT: i64 4295229452
; FINAL-NOT: i64 524300
; FINAL-NOT: i64 4295491596
; FINAL-NOT: poison

define void @test_nested_arguments(i32 %outer.value, i32 %child.value)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %outer = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
               ptr inttoptr (i64 30301 to ptr), i32 32, i1 false)
           to label %alloc.child unwind label %unwind
alloc.child:
  %child = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
               ptr inttoptr (i64 30302 to ptr), i32 24, i1 false)
           to label %body unwind label %unwind
body:
  %outer.int = getelementptr inbounds i8, ptr addrspace(1) %outer, i64 8
  %outer.ref = getelementptr inbounds i8, ptr addrspace(1) %outer, i64 16
  %child.int = getelementptr inbounds i8, ptr addrspace(1) %child, i64 8
  store atomic i32 %outer.value, ptr addrspace(1) %outer.int unordered, align 4
  store atomic ptr addrspace(1) %child, ptr addrspace(1) %outer.ref unordered, align 8
  store atomic i32 %child.value, ptr addrspace(1) %child.int unordered, align 4
  call void @sink2(ptr addrspace(1) %outer, ptr addrspace(1) %child)
       [ "deopt"(i32 99, i32 99,
                   i64 12, ptr addrspace(1) %outer,
                   i64 4294967308, ptr addrspace(1) %child) ]
  ret void
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; VO0's reference field recursively materializes VO1 first. The later direct
; VO1 argument sees it in the materialization set and emits no duplicate.
; TRACE-NESTED: PEA: Materialize function=@test_nested_arguments [VO=1] block=%body
; TRACE-NESTED: PEA: Materialize function=@test_nested_arguments [VO=0] block=%body

; FINAL-LABEL: define void @test_nested_arguments(
; FINAL: %outer = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; FINAL: %child = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; FINAL-NOT: invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; Child replay precedes the outer replay that stores the child's real identity.
; FINAL: %[[CHILD_SLOT:pea\.matslot[0-9]*]] = getelementptr inbounds i8, ptr addrspace(1) %child, i64 8
; FINAL-NEXT: store atomic i32 %child.value, ptr addrspace(1) %[[CHILD_SLOT]] unordered, align 4
; FINAL-NEXT: %[[OUTER_INT:pea\.matslot[0-9]*]] = getelementptr inbounds i8, ptr addrspace(1) %outer, i64 8
; FINAL-NEXT: store atomic i32 %outer.value, ptr addrspace(1) %[[OUTER_INT]] unordered, align 4
; FINAL-NEXT: %[[OUTER_REF:pea\.matslot[0-9]*]] = getelementptr inbounds i8, ptr addrspace(1) %outer, i64 16
; FINAL-NEXT: store atomic ptr addrspace(1) %child, ptr addrspace(1) %[[OUTER_REF]] unordered, align 8
; FINAL-NEXT: call void @sink2(ptr addrspace(1) %outer, ptr addrspace(1) %child)
; FINAL-SAME: [ "deopt"(i32 99, i32 99, i64 12, ptr addrspace(1) %outer, i64 4294967308, ptr addrspace(1) %child) ]
; FINAL-NOT: i64 262156
; FINAL-NOT: i64 4295229452
; FINAL-NOT: i64 524300
; FINAL-NOT: i64 4295491596
; FINAL-NOT: poison

define i32 @test_call_or_not(i1 %do.call, i32 %value)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %obj = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
             ptr inttoptr (i64 40401 to ptr), i32 24, i1 false)
         to label %body unwind label %unwind
body:
  %field = getelementptr inbounds i8, ptr addrspace(1) %obj, i64 8
  store atomic i32 %value, ptr addrspace(1) %field unordered, align 4
  br i1 %do.call, label %call, label %no.call
call:
  call void @sink2(ptr addrspace(1) %obj, ptr addrspace(1) %obj)
       [ "deopt"(i32 99, i32 99, i64 12, ptr addrspace(1) %obj) ]
  ret i32 -1
no.call:
  %result = load atomic i32, ptr addrspace(1) %field unordered, align 4
  ret i32 %result
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; The effect belongs to the call predecessor, never the no-call arm.
; TRACE-BRANCH: PEA: Materialize function=@test_call_or_not [VO=0] block=%call

; FINAL-LABEL: define i32 @test_call_or_not(
; FINAL: %obj = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; FINAL-NOT: invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; FINAL: call:
; FINAL-NEXT: %[[BRANCH_SLOT:pea\.matslot[0-9]*]] = getelementptr inbounds i8, ptr addrspace(1) %obj, i64 8
; FINAL-NEXT: store atomic i32 %value, ptr addrspace(1) %[[BRANCH_SLOT]] unordered, align 4
; FINAL-NEXT: call void @sink2(ptr addrspace(1) %obj, ptr addrspace(1) %obj)
; FINAL: no.call:
; FINAL-NOT: pea.matslot
; FINAL-NOT: store atomic
; FINAL-NOT: jeandle.new_instance
; FINAL: ret i32 %value
; FINAL-NOT: poison

!java-method-compilation = !{}
