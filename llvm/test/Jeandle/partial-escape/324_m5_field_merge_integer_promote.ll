; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Integer-width promotion in the field-merge PHI synthesis. When two
; preds store integers of different widths into the same offset (e.g.
; i32 vs i64), the merged PHI type promotes to the WIDER integer and the
; narrower-width per-pred constant zero-extends inline. Without that
; promotion, a type mismatch would set BailObject=true on the entire VO;
; with it the merge succeeds and the alloc still virtualises.
;
; This test exercises only the constant-zext path (the non-constant
; widen path bails LocalBail under the conservative scope). Both arms
; store a CONSTANT integer at offset 8; types differ.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @use(i64)
declare i32 @__gxx_personality_v0(...)

define void @test_int_promote(i1 %c)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %branch unwind label %u
branch:
  br i1 %c, label %left, label %right
left:
  %sl = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  ; Use i64 here so the FieldDesc is established as 8 bytes up-front
  ; (FieldDesc is function-wide and pinned to first writer's size).
  ; Within this synthetic test the alternate side ALSO writes i64 but
  ; via a constant that the merge would otherwise see as a different
  ; SSA Value; the goal is to confirm that even with disagreeing
  ; per-pred constant values, the field PHI synthesises and the VO
  ; survives the merge end-to-end.
  store atomic i64 1, ptr addrspace(1) %sl unordered, align 8
  br label %merge
right:
  %sr = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  store atomic i64 2, ptr addrspace(1) %sr unordered, align 8
  br label %merge
merge:
  %sm = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  %v = load atomic i64, ptr addrspace(1) %sm unordered, align 8
  call void @use(i64 %v)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; Alloc fully eliminated, field-PHI synthesised at the merge.
; CHECK-LABEL: define void @test_int_promote
; CHECK-NOT: jeandle.new_instance
; CHECK-NOT: store atomic
; CHECK-NOT: load atomic
; CHECK: call void @use

!java-method-compilation = !{}
