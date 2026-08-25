; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; PEA: invariant F2 in PartialEscape.h forbids ref↔primitive coercion at
; the same slot — GC machinery sees a non-oop where it expects an oop, or
; vice-versa. Storing `ptr addrspace(1) null` and loading `i64` (same bit
; width on x86_64) must bail to ineligible. The original allocation, store,
; and load remain in the IR; no coercion is synthesized.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)

declare i32 @__gxx_personality_v0(...)

define i64 @test_coerce_bail_ref_to_primitive() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %obj = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 24, i1 false)
         to label %normal unwind label %unwind

normal:
  %slot = getelementptr inbounds i8, ptr addrspace(1) %obj, i64 8
  store atomic ptr addrspace(1) null, ptr addrspace(1) %slot unordered, align 8
  %v = load atomic i64, ptr addrspace(1) %slot unordered, align 8
  ret i64 %v

unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define i64 @test_coerce_bail_ref_to_primitive()
; CHECK: jeandle.new_instance
; CHECK: store atomic ptr addrspace(1)
; CHECK: load atomic i64
; CHECK-NOT: pea.coerce
; CHECK: ret i64

!java-method-compilation = !{}
