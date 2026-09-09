; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; PEA: store an i32 bit-pattern into a virtual's slot and read it back as
; a float. The bit widths match (32 == 32) and both sides are primitive
; scalars, so PEA synthesizes a `bitcast i32 ... to float` and eliminates
; the allocation + store + load.
;
; 0x40490FDB is the IEEE-754 single-precision bit pattern of pi (3.14159274...).

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)

declare i32 @__gxx_personality_v0(...)

define float @test_coerce_i32_to_float() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %obj = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
         to label %normal unwind label %unwind

normal:
  %slot = getelementptr inbounds i8, ptr addrspace(1) %obj, i64 8
  store atomic i32 1078530011, ptr addrspace(1) %slot unordered, align 4
  %v = load atomic float, ptr addrspace(1) %slot unordered, align 4
  ret float %v

unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define float @test_coerce_i32_to_float()
; CHECK-NOT: jeandle.new_instance
; CHECK-NOT: store
; CHECK-NOT: load
; CHECK: %[[CO:.*]] = bitcast i32 1078530011 to float
; CHECK: ret float %[[CO]]

!java-method-compilation = !{}
