; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Store i64 into a virtual's slot at offset 8, then read both halves as i32 —
; both are sub-slot narrowing reads (i64 -> i32). PEA does not support
; sub-slot / narrowing loads — the loads bail to ineligible and the object
; materializes: alloc, store, and loads survive intact, no coercion
; synthesized.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)

declare i32 @__gxx_personality_v0(...)

define i64 @test_coerce_i64_to_i32_halves() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %obj = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 24, i1 false)
         to label %normal unwind label %unwind

normal:
  %slot = getelementptr inbounds i8, ptr addrspace(1) %obj, i64 8
  %hi   = getelementptr inbounds i8, ptr addrspace(1) %obj, i64 12
  store atomic i64 -81985529216486896, ptr addrspace(1) %slot unordered, align 8
  %lo32 = load atomic i32, ptr addrspace(1) %slot unordered, align 4
  %hi32 = load atomic i32, ptr addrspace(1) %hi unordered, align 4
  %lo64 = zext i32 %lo32 to i64
  %hi64 = zext i32 %hi32 to i64
  %hisl = shl i64 %hi64, 32
  %sum  = or i64 %lo64, %hisl
  ret i64 %sum

unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define i64 @test_coerce_i64_to_i32_halves()
; CHECK: jeandle.new_instance
; CHECK: store atomic i64
; CHECK: load atomic i32
; CHECK-NOT: pea.coerce
; CHECK: ret i64

!java-method-compilation = !{}
