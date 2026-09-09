; RUN: opt -passes=verify -disable-output %s
; RUN: opt -S -verify-each \
; RUN:   -passes="require<partial-escape-analysis>,partial-escape-transform" \
; RUN:   %s | FileCheck %s

; Constant-offset arithmetic is analyzer metadata, not LLVM IR arithmetic.
; If an accumulated offset or a half-open byte-range endpoint cannot be
; represented by int64_t, PEA must keep the access real.  It must not rely on
; C++ signed wraparound and then eliminate the allocation and access.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare i32 @__gxx_personality_v0(...)

define void @nested_min_minus_one() gc "hotspotgc"
    personality ptr @__gxx_personality_v0 {
entry:
  %obj = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 73601 to ptr), i32 16, i1 false)
      to label %body unwind label %unwind
body:
  %min = getelementptr i8, ptr addrspace(1) %obj,
      i64 -9223372036854775808
  %underflow = getelementptr i8, ptr addrspace(1) %min, i64 -1
  store atomic i8 7, ptr addrspace(1) %underflow unordered, align 1
  ret void
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @nested_min_minus_one(
; CHECK: %obj = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK: %min = getelementptr i8, ptr addrspace(1) %obj, i64 -9223372036854775808
; CHECK: %underflow = getelementptr i8, ptr addrspace(1) %min, i64 -1
; CHECK: store atomic i8 7, ptr addrspace(1) %underflow unordered, align 1

define void @densemap_tombstone_offset() gc "hotspotgc"
    personality ptr @__gxx_personality_v0 {
entry:
  %obj = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 73604 to ptr), i32 16, i1 false)
      to label %body unwind label %unwind
body:
  %sentinel = getelementptr i8, ptr addrspace(1) %obj,
      i64 9223372036854775806
  store atomic i8 8, ptr addrspace(1) %sentinel unordered, align 1
  ret void
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @densemap_tombstone_offset(
; CHECK: %obj = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK: %sentinel = getelementptr i8, ptr addrspace(1) %obj, i64 9223372036854775806
; CHECK: store atomic i8 8, ptr addrspace(1) %sentinel unordered, align 1

define void @field_endpoint_max_plus_one() gc "hotspotgc"
    personality ptr @__gxx_personality_v0 {
entry:
  %obj = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 73602 to ptr), i32 16, i1 false)
      to label %body unwind label %unwind
body:
  %last = getelementptr i8, ptr addrspace(1) %obj,
      i64 9223372036854775807
  store atomic i8 9, ptr addrspace(1) %last unordered, align 1
  ret void
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @field_endpoint_max_plus_one(
; CHECK: %obj = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK: %last = getelementptr i8, ptr addrspace(1) %obj, i64 9223372036854775807
; CHECK: store atomic i8 9, ptr addrspace(1) %last unordered, align 1

define i8 @load_endpoint_max_plus_one() gc "hotspotgc"
    personality ptr @__gxx_personality_v0 {
entry:
  %obj = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 73603 to ptr), i32 16, i1 false)
      to label %body unwind label %unwind
body:
  %last = getelementptr i8, ptr addrspace(1) %obj,
      i64 9223372036854775807
  %value = load atomic i8, ptr addrspace(1) %last unordered, align 1
  ret i8 %value
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define i8 @load_endpoint_max_plus_one(
; CHECK: %obj = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK: %last = getelementptr i8, ptr addrspace(1) %obj, i64 9223372036854775807
; CHECK: %value = load atomic i8, ptr addrspace(1) %last unordered, align 1
; CHECK: ret i8 %value

!java-method-compilation = !{}
