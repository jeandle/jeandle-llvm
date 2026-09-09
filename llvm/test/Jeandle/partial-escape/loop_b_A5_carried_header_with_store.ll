; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; The loop header block contains a NON-PHI instruction (a store to the
; carried field) in addition to its PHI + branch. This pins the capture
; point: the header's merged state B must be the merge RESULT (taken after
; mergeStates, BEFORE the header instruction walk), not BlockExits[header]
; (which includes the header store's effect). The header store is dead
; (overwritten by the body store before any load), so it is eliminated and
; the body load still folds to the just-stored %i.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @use(i32)
declare i32 @__gxx_personality_v0(...)

define void @test_carried_header_with_store(i32 %n) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 40501 to ptr), i32 16, i1 false)
       to label %prep unwind label %u
prep:
  %s = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  store atomic i32 1, ptr addrspace(1) %s unordered, align 4
  br label %loop
loop:
  %i = phi i32 [ 0, %prep ], [ %i1, %body ]
  ; header non-PHI instruction: store a constant to the carried field.
  store atomic i32 7, ptr addrspace(1) %s unordered, align 4
  %c = icmp slt i32 %i, %n
  br i1 %c, label %body, label %exit
body:
  store atomic i32 %i, ptr addrspace(1) %s unordered, align 4
  %v = load atomic i32, ptr addrspace(1) %s unordered, align 4
  call void @use(i32 %v)
  %i1 = add i32 %i, 1
  br label %loop
exit:
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; Alloc + the dead header store + body store/load all eliminated; @use sees %i.
; CHECK-LABEL: define void @test_carried_header_with_store
; CHECK-NOT: jeandle.new_instance
; CHECK-NOT: store atomic
; CHECK-NOT: load atomic
; CHECK: call void @use(i32 %i)

!java-method-compilation = !{}
