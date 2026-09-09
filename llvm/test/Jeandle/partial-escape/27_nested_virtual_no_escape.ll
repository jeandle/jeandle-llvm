; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Nested virtuals with NO escape: outer holds inner via a tracked field but
; nothing leaks either pointer. Both allocations should be eliminated entirely
; and the field-store of inner-into-outer should be elided. After PEA the
; function body contains no jeandle.new_instance calls and no atomic stores.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare i32 @__gxx_personality_v0(...)

define void @test_nested_no_escape() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %inner = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
              ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
           to label %nA unwind label %u1
nA:
  %outer = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
              ptr inttoptr (i64 67890 to ptr), i32 16, i1 false)
           to label %nB unwind label %u2
nB:
  %slot = getelementptr inbounds i8, ptr addrspace(1) %outer, i64 8
  store atomic ptr addrspace(1) %inner, ptr addrspace(1) %slot unordered, align 8
  ret void
u1:
  %lp1 = landingpad i64 cleanup
  resume i64 %lp1
u2:
  %lp2 = landingpad i64 cleanup
  resume i64 %lp2
}

; CHECK-LABEL: define void @test_nested_no_escape
; CHECK-NOT: jeandle.new_instance
; CHECK-NOT: store atomic
; CHECK: ret void

!java-method-compilation = !{}
