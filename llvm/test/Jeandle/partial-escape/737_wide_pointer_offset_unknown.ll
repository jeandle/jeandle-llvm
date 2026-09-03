; RUN: opt -passes=verify -disable-output %s
; RUN: opt -S -verify-each \
; RUN:   -passes="require<partial-escape-analysis>,partial-escape-transform" \
; RUN:   %s | FileCheck %s

; A legal target may use a pointer index wider than 64 bits.  The GEP offset
; below is 2^64 and therefore cannot be represented by PEA's int64_t field
; model.  It must make the access unknown instead of asserting in
; APInt::getSExtValue or truncating the address.

target datalayout = "e-p:64:64-p1:128:128-p3:128:128"

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare i32 @__gxx_personality_v0(...)

define void @wide_pointer_offset_unknown() gc "hotspotgc"
    personality ptr @__gxx_personality_v0 {
entry:
  %obj = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 73701 to ptr), i32 16, i1 false)
      to label %body unwind label %unwind
body:
  %wide = getelementptr i8, ptr addrspace(1) %obj,
      i128 18446744073709551616
  store atomic i8 11, ptr addrspace(1) %wide unordered, align 1
  ret void
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @wide_pointer_offset_unknown(
; CHECK: %obj = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK: %wide = getelementptr i8, ptr addrspace(1) %obj, i128 18446744073709551616
; CHECK: store atomic i8 11, ptr addrspace(1) %wide unordered, align 1

!java-method-compilation = !{}
