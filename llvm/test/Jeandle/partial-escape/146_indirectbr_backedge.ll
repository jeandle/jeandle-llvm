; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Coverage for an indirectbr back-edge. This CFG is reducible: %head dominates
; the latch, so LoopInfo can represent it as a natural loop. The test locks
; down the conservative output for this unusual terminator, but deliberately
; makes no claim that the unsafe-cyclic-blocks safety net fired.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare i32 @__gxx_personality_v0(...)

@labels = external addrspace(1) global [2 x ptr]

define void @test_indirectbr(i32 %n, ptr %target) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %obj = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
              ptr inttoptr (i64 9999 to ptr), i32 16, i1 false)
           to label %head unwind label %u

head:
  %slot = getelementptr inbounds i8, ptr addrspace(1) %obj, i64 8
  store atomic i32 7, ptr addrspace(1) %slot unordered, align 4
  br label %indirect

indirect:
  ; Back-edge to %head via indirectbr.
  indirectbr ptr %target, [label %head, label %exit]

exit:
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @test_indirectbr
; CHECK: jeandle.new_instance({{.*}}i64 9999
; CHECK: store atomic i32 7

!java-method-compilation = !{}
