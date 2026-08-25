; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Store float into a virtual's slot, load i32 at the same offset.
; Same bit width (32 == 32), both primitives -> BitCast (float -> i32).
; Covers the float-->int direction (test 60 covers int-->float).

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)

declare i32 @__gxx_personality_v0(...)

define i32 @test_coerce_float_to_i32() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %obj = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
         to label %normal unwind label %unwind

normal:
  %slot = getelementptr inbounds i8, ptr addrspace(1) %obj, i64 8
  store atomic float 0x400921FB60000000, ptr addrspace(1) %slot unordered, align 4
  %v = load atomic i32, ptr addrspace(1) %slot unordered, align 4
  ret i32 %v

unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define i32 @test_coerce_float_to_i32()
; CHECK-NOT: jeandle.new_instance
; CHECK-NOT: store
; CHECK-NOT: load
; CHECK-NOT: lshr
; CHECK-NOT: trunc
; CHECK: %[[C:.*]] = bitcast float {{.*}} to i32
; CHECK: ret i32 %[[C]]

!java-method-compilation = !{}
