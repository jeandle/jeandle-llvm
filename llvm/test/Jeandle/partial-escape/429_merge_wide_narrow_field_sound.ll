; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; mergeFieldStates two-slot / byte-array gap — non-regression.
;
; Two predecessors write the same field at different widths: pred1 stores an
; i64 at offset 0, pred2 stores two i8s at offsets 0 and 1. A byte-count
; merge would have to widen pred2's i8 to i64 WITHOUT
; discarding the i8 at offset 1. Jeandle does not reach that merge: processStore's
; getOrCreateFieldIndex bails on the width mismatch at offset 0, so the object
; escapes and the stores/load survive as real operations — sound, no
; mis-merge. This test pins that sound behaviour. (mergeFieldStates also
; carries a defensive entry-defaults guard so the merge stays sound if
; the width-conflict bail is ever relaxed.)

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @use(i64)
declare i32 @__gxx_personality_v0(...)

define void @test_merge_wide_narrow_field(i1 %c) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
  ptr inttoptr (i64 12345 to ptr), i32 32, i1 false)
  to label %split unwind label %u
split:
  br i1 %c, label %p1, label %p2
p1:
  store atomic i64 1541, ptr addrspace(1) %o unordered, align 8
  br label %merge
p2:
  %f1 = getelementptr inbounds i8, ptr addrspace(1) %o, i64 1
  store atomic i8 5, ptr addrspace(1) %o unordered, align 1
  store atomic i8 6, ptr addrspace(1) %f1 unordered, align 1
  br label %merge
merge:
  %r = load atomic i64, ptr addrspace(1) %o unordered, align 8
  call void @use(i64 %r)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @test_merge_wide_narrow_field
; The object escapes (no virtualization, no mis-merge); all accesses survive.
; CHECK: invoke hotspotcc{{.*}}@jeandle.new_instance
; CHECK: store atomic i64 1541
; CHECK: store atomic i8 5
; CHECK: load atomic i64
; CHECK: call void @use

!java-method-compilation = !{}
