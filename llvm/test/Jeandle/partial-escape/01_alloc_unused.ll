; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; PEA: an allocation whose result is never used (dead allocation)
; should be removed.  The invoke is rewritten to an unconditional branch to
; the normal destination, and the unwind block is cleaned up as unreachable.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)

declare i32 @__gxx_personality_v0(...)

define void @test_unused_alloc() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %obj = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
         to label %normal unwind label %unwind

normal:
  ret void

unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @test_unused_alloc()
; CHECK-NOT: jeandle.new_instance
; CHECK:     ret void

!java-method-compilation = !{}
