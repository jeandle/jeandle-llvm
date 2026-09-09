; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Pre-LCSSA loop shape: the post-loop block consumes a body-defined
; value (the field-load %v) directly, with no LCSSA-style single-incoming
; PHI at the exit. Jeandle's pipeline runs PEA BEFORE LLVM's
; LoopSimplify/LCSSA, so this is the realistic input shape.
;
; The alloc is before the loop; the body stores %i into a field and reads
; it back; the post-loop block reads the field too. Because the
; field-load in the exit folds via the loop-header's field PHI
; (synthesized by the loop fixpoint), the post-loop @use receives the
; PHI value — no separate exit-block PHI is needed for this branch.
; Verifies the "still-virtual at exit" path in the absence of canonical
; LCSSA structure.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @use(i32)
declare i32 @__gxx_personality_v0(...)

define i32 @test_a6_pre_lcssa(i32 %n, i32 %x) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
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
  %i1 = add i32 %i, 1
  br label %loop
exit:
  ; Raw post-loop field read — NO LCSSA PHI wrapping. The fold to the
  ; loop-header field PHI must work even though the input IR has no
  ; canonical loop-exit value-proxy.
  %v = load atomic i32, ptr addrspace(1) %s unordered, align 4
  ret i32 %v
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; The alloc and all field stores/loads are eliminated. The post-loop
; return value is fed by the loop-header field PHI [preheader=%x,
; body=%i] — this is the "still-virtual at loop exit, field PHI carries
; through" case.
; CHECK-LABEL: define i32 @test_a6_pre_lcssa
; CHECK-NOT: jeandle.new_instance
; CHECK-NOT: store atomic
; CHECK-NOT: load atomic
; CHECK: %[[FP:[A-Za-z0-9._]+]] = phi i32 [ %i, %body ], [ %x, %prep ]
; CHECK: ret i32 %[[FP]]

!java-method-compilation = !{}
