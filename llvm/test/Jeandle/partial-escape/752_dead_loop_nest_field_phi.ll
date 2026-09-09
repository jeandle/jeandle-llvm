; RUN: opt -S -verify-each \
; RUN:   -passes="require<partial-escape-analysis>,partial-escape-transform" \
; RUN:   %s | FileCheck %s
; RUN: opt -S -verify-each \
; RUN:   -passes="partial-escape-iterative" \
; RUN:   %s | FileCheck %s --check-prefix=ITERATIVE

; The loop's only forward edge is PEA-proven dead (%is.null folds to false on
; the still-virtual receiver) while the latch is still Unseen. The analyzer
; must treat the whole loop nest as dead: publish dead exits for every loop
; block and let the ordinary dead-pred merge machinery pad the merge PHI with
; a poison slot that the final cleanup removes. Pre-fix, the unseeded body
; pass deferred every loop block at the entry gate, nothing published an exit
; for the loop nest, the outer merge silently skipped the loop predecessor,
; and the malformed %pea.field.phi crashed the transform's
; EliminateUnreachableBlocks (removePredecessor -> removeIncomingValue(-1)).

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare i32 @__gxx_personality_v0(...)

define i32 @dead_loop_nest_field_phi(i1 %choose, i32 %limit)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 75201 to ptr), i32 24, i1 false)
      to label %guard unwind label %alloc.unwind

guard:
  %is.null = icmp eq ptr addrspace(1) %o, null
  br i1 %is.null, label %preheader, label %live.dispatch

preheader:
  br label %loop.header

loop.header:
  %i = phi i32 [ 0, %preheader ], [ %inc, %latch ]
  br label %latch

latch:
  %inc = add i32 %i, 1
  %more = icmp ult i32 %inc, %limit
  br i1 %more, label %loop.header, label %loop.exit

loop.exit:
  br label %merge

live.dispatch:
  br i1 %choose, label %left, label %right

left:
  %left.field = getelementptr inbounds i8, ptr addrspace(1) %o, i64 16
  store atomic i32 61, ptr addrspace(1) %left.field unordered, align 4
  br label %merge

right:
  %right.field = getelementptr inbounds i8, ptr addrspace(1) %o, i64 16
  store atomic i32 62, ptr addrspace(1) %right.field unordered, align 4
  br label %merge

merge:
  %reload = getelementptr inbounds i8, ptr addrspace(1) %o, i64 16
  %value = load atomic i32, ptr addrspace(1) %reload unordered, align 4
  ret i32 %value

alloc.unwind:
  %ex = landingpad i64 cleanup
  resume i64 %ex
}

; CHECK-LABEL: define i32 @dead_loop_nest_field_phi(
; CHECK-NOT: @jeandle.new_instance
; CHECK-NOT: preheader:
; CHECK-NOT: loop.header:
; CHECK-NOT: latch:
; CHECK-NOT: loop.exit:
; CHECK-NOT: alloc.unwind:
; CHECK: merge:
; CHECK-NEXT: %pea.field.phi = phi i32 [ 62, %right ], [ 61, %left ]
; CHECK-NEXT: ret i32 %pea.field.phi
; CHECK-NOT: poison

; The iterative pipeline additionally canonicalizes between rounds; only pin
; the crash-freedom and the elimination here.
; ITERATIVE-LABEL: define i32 @dead_loop_nest_field_phi(
; ITERATIVE-NOT: @jeandle.new_instance
; ITERATIVE-NOT: preheader:
; ITERATIVE-NOT: loop.header:
; ITERATIVE-NOT: latch:
; ITERATIVE-NOT: loop.exit:
; ITERATIVE: ret i32
; ITERATIVE-NOT: poison

!java-method-compilation = !{}
