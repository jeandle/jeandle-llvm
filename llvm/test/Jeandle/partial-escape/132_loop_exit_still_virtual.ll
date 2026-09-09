; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; VO is STILL VIRTUAL at the loop exit (never escapes anywhere). The
; loop body mutates a field, reads it back, and feeds the read scalar to
; @use. After the loop, the post-loop block reads the same field and
; consumes that scalar too. Both reads must fold to the just-stored value
; via processLoad.
;
; This exercises the "for each VO still virtual at the loop exit's
; snapshot, the FieldStates must be visible to the outer block" branch.
; The existing snapshotExitState / inheritFromExit machinery carries
; Virtuals + FieldStates from the loop's exiting block into the post-loop
; block.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @use(i32)
declare i32 @__gxx_personality_v0(...)

define void @test_a6_still_virtual_at_exit(i32 %n, i32 %x) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %prep unwind label %u
prep:
  %s = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  store atomic i32 %x, ptr addrspace(1) %s unordered, align 4
  br label %loop
loop:
  %i = phi i32 [ 0, %prep ], [ %i1, %body ]
  %c = icmp slt i32 %i, %n
  br i1 %c, label %body, label %exit
body:
  store atomic i32 %i, ptr addrspace(1) %s unordered, align 4
  %v = load atomic i32, ptr addrspace(1) %s unordered, align 4
  call void @use(i32 %v)
  %i1 = add i32 %i, 1
  br label %loop
exit:
  ; Post-loop field read. The VO is still virtual at the loop exit's
  ; snapshot; FieldStates must propagate through inheritFromExit so this
  ; load folds to the field value that flows out of the loop.
  %v2 = load atomic i32, ptr addrspace(1) %s unordered, align 4
  call void @use(i32 %v2)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; The alloc, both stores, and both loads are all eliminated. The body's
; @use receives %i (the just-stored scalar). The post-loop @use receives
; the loop-exit value of the field, which is the loop-header PHI of the
; preheader's %x and the body's %i.
; CHECK-LABEL: define void @test_a6_still_virtual_at_exit
; CHECK-NOT: jeandle.new_instance
; CHECK-NOT: store atomic
; CHECK-NOT: load atomic
; CHECK: call void @use(i32 %i)
; The post-loop use is fed by the field PHI synthesised at the loop
; header (preheader=%x, body=%i).
; CHECK: call void @use(i32 %{{.*}})

!java-method-compilation = !{}
