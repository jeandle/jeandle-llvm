; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" -jeandle-vm-callback-log=%S/Inputs/686_array_float_double_deopt.cblog %s | FileCheck %s

; Float and double virtual-array descriptors use typed floating-point defaults
; and preserve every touched ConstantFP exactly. This covers zero-length
; arrays, an untouched element, explicit +0 and -0, a NaN payload, and a
; finite non-default value for both element kinds.

declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32, i1, i1)
declare void @safepoint()
declare i32 @__gxx_personality_v0(...)

define void @float_array_zero_length() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %arr = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
            ptr inttoptr (i64 68601 to ptr), i32 0, i32 16, i32 16, i32 1048576, i1 false, i1 false)
         to label %normal unwind label %unwind
normal:
  call void @safepoint()
       [ "deopt"(i32 10, i32 10, i64 12, ptr addrspace(1) %arr) ]
  ret void
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @float_array_zero_length
; CHECK-NOT: jeandle.new_array
; CHECK: call void @safepoint()
; CHECK-SAME: [ "deopt"(i32 10, i32 10,
; T_ARRAY descriptor, klass 68601, field_count/length 0.
; CHECK-SAME: i64 262157, i64 68601, i32 0,
; CHECK-SAME: i64 524300, i32 0) ]
; CHECK-NOT: addrspace(1) %arr

define void @double_array_zero_length() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %arr = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
            ptr inttoptr (i64 68602 to ptr), i32 0, i32 16, i32 16, i32 1048576, i1 false, i1 false)
         to label %normal unwind label %unwind
normal:
  call void @safepoint()
       [ "deopt"(i32 20, i32 20, i64 12, ptr addrspace(1) %arr) ]
  ret void
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @double_array_zero_length
; CHECK-NOT: jeandle.new_array
; CHECK: call void @safepoint()
; CHECK-SAME: [ "deopt"(i32 20, i32 20,
; T_ARRAY descriptor, klass 68602, field_count/length 0.
; CHECK-SAME: i64 262157, i64 68602, i32 0,
; CHECK-SAME: i64 524300, i32 0) ]
; CHECK-NOT: addrspace(1) %arr

define void @float_array_values() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %arr = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
            ptr inttoptr (i64 68603 to ptr), i32 5, i32 36, i32 16, i32 1048576, i1 false, i1 false)
         to label %normal unwind label %unwind
normal:
  %base = getelementptr inbounds i8, ptr addrspace(1) %arr, i64 16
  %p1 = getelementptr inbounds float, ptr addrspace(1) %base, i64 1
  %p2 = getelementptr inbounds float, ptr addrspace(1) %base, i64 2
  %p3 = getelementptr inbounds float, ptr addrspace(1) %base, i64 3
  %p4 = getelementptr inbounds float, ptr addrspace(1) %base, i64 4
  store atomic float 0.0, ptr addrspace(1) %p1 unordered, align 4
  store atomic float -0.0, ptr addrspace(1) %p2 unordered, align 4
  store atomic float 0x7FF8000020000000, ptr addrspace(1) %p3 unordered, align 4
  store atomic float 1.5, ptr addrspace(1) %p4 unordered, align 4
  call void @safepoint()
       [ "deopt"(i32 30, i32 30, i64 12, ptr addrspace(1) %arr) ]
  ret void
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @float_array_values
; CHECK-NOT: jeandle.new_array
; CHECK: call void @safepoint()
; CHECK-SAME: [ "deopt"(i32 30, i32 30,
; T_ARRAY descriptor, klass 68603, field_count/length 5.
; CHECK-SAME: i64 262157, i64 68603, i32 5,
; Untouched default +0.0, then explicit +0.0, -0.0, NaN payload, and 1.5.
; Each is one typed T_FLOAT wire pair.
; CHECK-SAME: i64 68719476742, float 0.000000e+00,
; CHECK-SAME: i64 85899345926, float 0.000000e+00,
; CHECK-SAME: i64 103079215110, float -0.000000e+00,
; CHECK-SAME: i64 120259084294, float 0x7FF8000020000000,
; CHECK-SAME: i64 137438953478, float 1.500000e+00,
; CHECK-SAME: i64 524300, i32 0) ]
; CHECK-NOT: addrspace(1) %arr

define void @double_array_values() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %arr = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
            ptr inttoptr (i64 68604 to ptr), i32 5, i32 56, i32 16, i32 1048576, i1 false, i1 false)
         to label %normal unwind label %unwind
normal:
  %base = getelementptr inbounds i8, ptr addrspace(1) %arr, i64 16
  %p1 = getelementptr inbounds double, ptr addrspace(1) %base, i64 1
  %p2 = getelementptr inbounds double, ptr addrspace(1) %base, i64 2
  %p3 = getelementptr inbounds double, ptr addrspace(1) %base, i64 3
  %p4 = getelementptr inbounds double, ptr addrspace(1) %base, i64 4
  store atomic double 0.0, ptr addrspace(1) %p1 unordered, align 8
  store atomic double -0.0, ptr addrspace(1) %p2 unordered, align 8
  store atomic double 0x7FF8000000000042, ptr addrspace(1) %p3 unordered, align 8
  store atomic double -2.25, ptr addrspace(1) %p4 unordered, align 8
  call void @safepoint()
       [ "deopt"(i32 40, i32 40, i64 12, ptr addrspace(1) %arr) ]
  ret void
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @double_array_values
; CHECK-NOT: jeandle.new_array
; CHECK: call void @safepoint()
; CHECK-SAME: [ "deopt"(i32 40, i32 40,
; T_ARRAY descriptor, klass 68604, field_count/length 5.
; CHECK-SAME: i64 262157, i64 68604, i32 5,
; Untouched default +0.0, then explicit +0.0, -0.0, NaN payload, and -2.25.
; Each is one typed T_DOUBLE wire pair; the parser expands it to two slots.
; CHECK-SAME: i64 68719476743, double 0.000000e+00,
; CHECK-SAME: i64 103079215111, double 0.000000e+00,
; CHECK-SAME: i64 137438953479, double -0.000000e+00,
; CHECK-SAME: i64 171798691847, double 0x7FF8000000000042,
; CHECK-SAME: i64 206158430215, double -2.250000e+00,
; CHECK-SAME: i64 524300, i32 0) ]
; CHECK-NOT: addrspace(1) %arr

!java-method-compilation = !{}
