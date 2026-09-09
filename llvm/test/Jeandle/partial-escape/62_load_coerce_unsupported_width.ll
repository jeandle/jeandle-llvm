; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; A load that STRADDLES two separately-stored sub-slots cannot be
; coerced — it would need a multi-slot read+concat which we don't
; implement. Here two i32 stores at adjacent offsets are followed by an
; i64 load spanning both: PEA must bail to ineligible, leaving the alloc,
; both stores, and the load intact.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)

declare i32 @__gxx_personality_v0(...)

define i64 @test_coerce_straddle_bail() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %obj = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 24, i1 false)
         to label %normal unwind label %unwind

normal:
  %slot0 = getelementptr inbounds i8, ptr addrspace(1) %obj, i64 8
  %slot4 = getelementptr inbounds i8, ptr addrspace(1) %obj, i64 12
  store atomic i32 305419896, ptr addrspace(1) %slot0 unordered, align 4
  store atomic i32 -2023406815, ptr addrspace(1) %slot4 unordered, align 4
  %v = load atomic i64, ptr addrspace(1) %slot0 unordered, align 8
  ret i64 %v

unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; The base must remain ineligible: the original allocation, both stores, and
; the i64 load survive in IR. No coercion was synthesized.
; CHECK-LABEL: define i64 @test_coerce_straddle_bail()
; CHECK: jeandle.new_instance
; CHECK: store atomic i32
; CHECK: store atomic i32
; CHECK: load atomic i64
; CHECK-NOT: pea.coerce
; CHECK: ret i64

!java-method-compilation = !{}
