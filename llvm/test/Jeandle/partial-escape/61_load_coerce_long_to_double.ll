; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; PEA: store an i64 bit-pattern into a virtual's slot and read it back as
; a double. Bit widths match (64 == 64); PEA synthesizes a `bitcast i64
; ... to double` and eliminates the allocation + store + load.
;
; 0x400921FB54442D18 is the IEEE-754 double-precision bit pattern of pi.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)

declare i32 @__gxx_personality_v0(...)

define double @test_coerce_i64_to_double() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %obj = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 24, i1 false)
         to label %normal unwind label %unwind

normal:
  %slot = getelementptr inbounds i8, ptr addrspace(1) %obj, i64 8
  store atomic i64 4614256656552045848, ptr addrspace(1) %slot unordered, align 8
  %v = load atomic double, ptr addrspace(1) %slot unordered, align 8
  ret double %v

unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define double @test_coerce_i64_to_double()
; CHECK-NOT: jeandle.new_instance
; CHECK-NOT: store
; CHECK-NOT: load
; CHECK: %[[CO:.*]] = bitcast i64 4614256656552045848 to double
; CHECK: ret double %[[CO]]

!java-method-compilation = !{}
