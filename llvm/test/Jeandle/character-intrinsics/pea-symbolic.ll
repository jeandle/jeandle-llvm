; RUN: opt -S -passes='character-intrinsic-specialization,instcombine,simplifycfg,require<partial-escape-analysis>,partial-escape-transform,instcombine,simplifycfg' -jeandle-vm-callback-log=%S/../string-intrinsics/Inputs/layout.cblog -verify-each %s | FileCheck %s

target datalayout = "e-p:64:64-p1:64:64"
@arrayOopDesc.base_offset_in_bytes.byte = constant i32 16
@arrayOopDesc.base_offset_in_bytes.char = constant i32 16
declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32, i1, i1)
declare i32 @__gxx_personality_v0(...)
declare hotspotcc i32 @jeandle.encode_array(ptr addrspace(1), i32, ptr addrspace(1), i32, i32, i1, i1)

; Bounded expansion exposes symbolic cells to PEA. The zext proves each
; character encodable without requiring the consumer to assume stable data.
; CHECK-LABEL: @encode_symbolic9(
; CHECK-NOT: jeandle.new_array
; CHECK-NOT: call
; CHECK: zext i8 %value to i32
; CHECK: add {{.*}}i32 {{.*}}, 9
; CHECK: ret i32
define i32 @encode_symbolic9(i8 %value) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %src = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10002 to ptr), i32 9, i32 34, i32 16, i32 100, i1 false, i1 false) to label %next unwind label %u
next:
  %dst = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 9, i32 25, i32 16, i32 100, i1 false, i1 false) to label %work unwind label %u
work:
  %sp = getelementptr i8, ptr addrspace(1) %src, i64 32
  %wide = zext i8 %value to i16
  store atomic i16 %wide, ptr addrspace(1) %sp unordered, align 2
  %count = call hotspotcc i32 @jeandle.encode_array(ptr addrspace(1) %src, i32 0, ptr addrspace(1) %dst, i32 0, i32 9, i1 false, i1 false)
  %dp = getelementptr i8, ptr addrspace(1) %dst, i64 24
  %cell = load atomic i8, ptr addrspace(1) %dp unordered, align 1
  %result = zext i8 %cell to i32
  %sum = add i32 %result, %count
  ret i32 %sum
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}


!java-method-compilation = !{}
