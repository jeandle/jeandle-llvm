; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Coverage for a switch-created back-edge. %head dominates the latch, so this
; is a normal reducible loop despite the switch terminator. The test does not
; claim to exercise the unsafe-cyclic-blocks safety net; it pins the current
; conservative output for this CFG shape.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare i32 @__gxx_personality_v0(...)

define void @test_switch_backedge(i32 %sel) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %obj = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
              ptr inttoptr (i64 1111 to ptr), i32 16, i1 false)
           to label %head unwind label %u

head:
  %slot = getelementptr inbounds i8, ptr addrspace(1) %obj, i64 8
  store atomic i32 9, ptr addrspace(1) %slot unordered, align 4
  br label %indirect

indirect:
  switch i32 %sel, label %head [ i32 0, label %exit ]

exit:
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @test_switch_backedge
; The allocation remains in the current conservative output.
; CHECK: jeandle.new_instance({{.*}}i64 1111

!java-method-compilation = !{}
