; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Cross-nest carry: a virtual allocated BEFORE the outer loop whose field is
; mutated inside the INNER loop body and read there. The field is therefore
; carried across BOTH the inner back-edge AND the outer back-edge. A
; field-PHI must be synthesized at the inner header (carrying the field
; around the inner loop) AND the field must remain consistent at the outer
; header. Exercises the deepest interaction of nested fixpoints with a
; single virtual object visible to both levels.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @use(i32)
declare i32 @__gxx_personality_v0(...)

define void @test_cross_nest_carry(i32 %n, i32 %m) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 40701 to ptr), i32 16, i1 false)
       to label %prep unwind label %u
prep:
  %s = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  store atomic i32 1, ptr addrspace(1) %s unordered, align 4
  br label %oloop
oloop:
  %i = phi i32 [ 0, %prep ], [ %i2, %oend ]
  %ci = icmp slt i32 %i, %n
  br i1 %ci, label %obody, label %oexit
obody:
  br label %iloop
iloop:
  %j = phi i32 [ 0, %obody ], [ %j1, %ibody ]
  %cj = icmp slt i32 %j, %m
  br i1 %cj, label %ibody, label %oend
ibody:
  store atomic i32 %i, ptr addrspace(1) %s unordered, align 4
  %w = load atomic i32, ptr addrspace(1) %s unordered, align 4
  call void @use(i32 %w)
  %j1 = add i32 %j, 1
  br label %iloop
oend:
  %i2 = add i32 %i, 1
  br label %oloop
oexit:
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; The alloc + stores + load are eliminated; @use receives the outer index %i.
; CHECK-LABEL: define void @test_cross_nest_carry
; CHECK-NOT: jeandle.new_instance
; CHECK-NOT: store atomic
; CHECK-NOT: load atomic
; CHECK: call void @use(i32 %i)

!java-method-compilation = !{}
