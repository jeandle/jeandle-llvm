; REQUIRES: asserts
; RUN: opt -verify-each -S \
; RUN:   -passes="require<partial-escape-analysis>,partial-escape-transform" \
; RUN:   %s | FileCheck %s
; RUN: opt -disable-output -passes="require<partial-escape-analysis>" \
; RUN:   -debug-only=partial-escape-analysis %s 2>&1 \
; RUN:   | FileCheck %s --check-prefix=DEBUG \
; RUN:     --implicit-check-not='fresh retry suppressing allocation %outer'

; The literal dead edge keeps %path.value from statically dominating the
; safepoint even though it is the only runtime value reaching join.  PEA
; therefore cannot replay %inner at the safepoint and must keep it real.
;
; The first Analyzer cannot close its exit snapshot if a kept-real %inner is
; omitted while %outer still carries VirtualRef(inner).  It must request a
; fresh Analyzer with %inner suppressed from the start.  The original inner
; initialization must survive, while the still-virtual outer may replay its
; reference at the sink.

@oop = external global ptr addrspace(1)

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1) nounwind
declare void @safepoint()
declare void @sink(ptr addrspace(1))

define void @loop_kept_real_nested_ref_retry(i1 %leave) gc "hotspotgc" {
entry:
  %inner = call hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 200 to ptr), i32 32, i1 false)
  %outer = call hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 100 to ptr), i32 32, i1 false)
  br i1 true, label %set, label %unset

set:
  %path.value = load ptr addrspace(1), ptr @oop
  %inner.field = getelementptr inbounds i8, ptr addrspace(1) %inner, i64 24
  store atomic ptr addrspace(1) %path.value,
      ptr addrspace(1) %inner.field unordered, align 8
  br label %join

unset:
  br label %join

join:
  %outer.ref = getelementptr inbounds i8, ptr addrspace(1) %outer, i64 16
  store atomic ptr addrspace(1) %inner,
      ptr addrspace(1) %outer.ref unordered, align 8
  br label %loop

loop:
  call void @safepoint()
      [ "deopt"(i32 99, i32 99, i64 12, ptr addrspace(1) %outer) ]
  br i1 %leave, label %exit, label %latch

latch:
  br label %loop

exit:
  call void @sink(ptr addrspace(1) %outer)
  ret void
}

; CHECK-LABEL: define void @loop_kept_real_nested_ref_retry(
; CHECK: %inner = call hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK: %outer = call hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK: set:
; CHECK: %path.value = load ptr addrspace(1), ptr @oop
; CHECK: %inner.field = getelementptr inbounds i8, ptr addrspace(1) %inner, i64 24
; CHECK-NEXT: store atomic ptr addrspace(1) %path.value, ptr addrspace(1) %inner.field unordered, align 8
; CHECK: join:
; CHECK-NOT: store atomic ptr addrspace(1) %inner
; CHECK: loop:
; CHECK: exit:
; CHECK: [[OUTER_REF:%.*]] = getelementptr inbounds i8, ptr addrspace(1) %outer, i64 16
; CHECK-NEXT: store atomic ptr addrspace(1) %inner, ptr addrspace(1) [[OUTER_REF]] unordered, align 8
; CHECK-NEXT: call void @sink(ptr addrspace(1) %outer)

; DEBUG: PEA: keep-real field unavailable VO=0 value= %path.value = load
; DEBUG: PEA: fresh retry suppressing allocation %inner in @loop_kept_real_nested_ref_retry

!java-method-compilation = !{}
