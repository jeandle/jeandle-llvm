; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Real loop fixpoint. An object is allocated BEFORE the loop, with a
; field stored in the preheader. The loop body writes a new value to the
; same field on every iteration and reads it back; the read flows into a
; scalar consumer (@use). The object itself never escapes the loop (no
; pointer-leak: only the loaded i32 is consumed).
;
; The loop fixpoint tracks the object through the back-edge: iteration 1
; sees both the preheader's f-value (=1) and the backedge's f-value
; (=%i); a field PHI is synthesised at the loop header; iteration 2
; produces the same FieldStates / Virtuals pattern at every loop block →
; convergence; the safety net is skipped; the alloc is fully eliminated.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @use(i32)
declare i32 @__gxx_personality_v0(...)

define void @test_alloc_before_loop_body_mut(i32 %n) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %prep unwind label %u
prep:
  %s = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  store atomic i32 1, ptr addrspace(1) %s unordered, align 4
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
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; The alloc, preheader store, and loop-body store/load are all eliminated.
; The body's @use call receives %i (the loaded scalar collapses to the
; just-stored value through processLoad on a known-virtual field).
; CHECK-LABEL: define void @test_alloc_before_loop_body_mut
; CHECK-NOT: jeandle.new_instance
; CHECK-NOT: store atomic
; CHECK-NOT: load atomic
; CHECK: call void @use(i32 %i)

!java-method-compilation = !{}
