; RUN: opt -passes=verify -disable-output %s
; RUN: opt -S -verify-each \
; RUN:   -passes="require<partial-escape-analysis>,partial-escape-transform" \
; RUN:   -jeandle-pea-max-array-length=4294967295 \
; RUN:   -jeandle-vm-callback-log=%S/Inputs/738_checked_array_offsets.cblog \
; RUN:   %s | FileCheck %s

; Array byte offsets use base + index * scale in access resolution and deopt
; planning.  An unrepresentable arithmetic result is unknown and forces the
; original array/access to stay real.  A representable int64_t offset that
; does not fit the descriptor's signed 32-bit Index field also makes the
; descriptor ineligible.

@arrayOopDesc.base_offset_in_bytes.int = private constant i64 16
@arrayOopDesc.element_size.int = private constant i64 4294967295
@arrayOopDesc.base_offset_in_bytes.byte = private constant i64 2147483648
@arrayOopDesc.element_size.byte = private constant i64 1

declare hotspotcc ptr addrspace(1) @jeandle.new_array(
    ptr, i32, i32, i32, i32, i1, i1)
declare void @safepoint()
declare i32 @__gxx_personality_v0(...)

define void @array_index_scale_add_overflow() gc "hotspotgc"
    personality ptr @__gxx_personality_v0 {
entry:
  %arr = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
      ptr inttoptr (i64 73801 to ptr), i32 -2147483646,
      i32 16, i32 16, i32 1048576, i1 false, i1 false)
      to label %body unwind label %unwind
body:
  %index = freeze i64 2147483649
  %scaled = mul i64 %index, 4294967295
  %byte.offset = add i64 %scaled, 16
  %cell = getelementptr i8, ptr addrspace(1) %arr, i64 %byte.offset
  store atomic i32 13, ptr addrspace(1) %cell unordered, align 4
  ret void
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @array_index_scale_add_overflow(
; CHECK: %arr = invoke hotspotcc ptr addrspace(1) @jeandle.new_array
; CHECK: %scaled = mul i64 %index, 4294967295
; CHECK: %byte.offset = add i64 %scaled, 16
; CHECK: %cell = getelementptr i8, ptr addrspace(1) %arr, i64 %byte.offset
; CHECK: store atomic i32 13, ptr addrspace(1) %cell unordered, align 4

define void @deopt_array_offset_not_encodable() gc "hotspotgc"
    personality ptr @__gxx_personality_v0 {
entry:
  %arr = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
      ptr inttoptr (i64 73802 to ptr), i32 1,
      i32 -2147483647, i32 -2147483648, i32 1048576, i1 false, i1 false)
      to label %body unwind label %unwind
body:
  %cell = getelementptr i8, ptr addrspace(1) %arr, i64 2147483648
  store atomic i8 17, ptr addrspace(1) %cell unordered, align 1
  call void @safepoint()
      [ "deopt"(i32 2, i32 2, i64 12, ptr addrspace(1) %arr) ]
  ret void
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @deopt_array_offset_not_encodable(
; CHECK: %arr = invoke hotspotcc ptr addrspace(1) @jeandle.new_array
; CHECK: %pea.matslot = getelementptr inbounds i8, ptr addrspace(1) %arr, i64 2147483648
; CHECK: store atomic i8 17, ptr addrspace(1) %pea.matslot unordered, align 1
; CHECK: call void @safepoint()
; CHECK-SAME: [ "deopt"(i32 2, i32 2, i64 12, ptr addrspace(1) %arr) ]
; CHECK-NOT: i64 262157
; CHECK-NOT: i64 524300

!java-method-compilation = !{}
