; RUN: opt -S -passes='java-op-length-folding,string-intrinsic-specialization,partial-escape-iterative,instcombine,simplifycfg' -jeandle-vm-callback-log=%S/Inputs/layout.cblog -verify-each %s | FileCheck %s
target datalayout = "e-p:64:64-p1:64:64"
@arrayOopDesc.base_offset_in_bytes.byte = constant i32 16
declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32, i1, i1)
declare i32 @jeandle.arraylength(ptr addrspace(1))
declare i32 @jeandle.string_compare(ptr addrspace(1), i32, ptr addrspace(1), i32, i32)
declare i32 @__gxx_personality_v0(...)

; CHECK-LABEL: @local_vs_material(
; CHECK-NOT: @jeandle.new_array
; CHECK-NOT: @jeandle.string_compare
; CHECK: load atomic i8
; CHECK: ret i32
define i32 @local_vs_material(i8 %character, ptr addrspace(1) %material) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %length = call i32 @jeandle.arraylength(ptr addrspace(1) %material)
  %one = icmp eq i32 %length, 1
  br i1 %one, label %allocate, label %exit
allocate:
  %src = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 1, i32 24, i32 16, i32 100, i1 false, i1 false) to label %work unwind label %u
work:
  %sp = getelementptr i8, ptr addrspace(1) %src, i64 16
  store atomic i8 %character, ptr addrspace(1) %sp unordered, align 1
  %left = call i32 @jeandle.arraylength(ptr addrspace(1) %src)
  %right = call i32 @jeandle.arraylength(ptr addrspace(1) %material)
  %result = call i32 @jeandle.string_compare(ptr addrspace(1) %src, i32 %left, ptr addrspace(1) %material, i32 %right, i32 0)
  ret i32 %result
exit:
  ret i32 -1
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}
!java-method-compilation = !{}
