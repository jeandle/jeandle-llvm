; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; A widening load (EntryWidth < LoadWidth) cannot be coerced from a
; single sub-bit-width slot — coercion would require a multi-slot read
; and concat. We bail to ineligible: the original alloc, store, and load
; survive intact, no coercion synthesized.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)

declare i32 @__gxx_personality_v0(...)

define i64 @test_coerce_widen_bail() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %obj = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 24, i1 false)
         to label %normal unwind label %unwind

normal:
  %slot = getelementptr inbounds i8, ptr addrspace(1) %obj, i64 8
  store atomic i32 305419896, ptr addrspace(1) %slot unordered, align 4
  %v = load atomic i64, ptr addrspace(1) %slot unordered, align 8
  ret i64 %v

unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define i64 @test_coerce_widen_bail()
; CHECK: jeandle.new_instance
; CHECK: store atomic i32
; CHECK: load atomic i64
; CHECK-NOT: pea.coerce
; CHECK: ret i64

!java-method-compilation = !{}
