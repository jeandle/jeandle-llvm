; RUN: opt -S -passes='string-intrinsic-specialization,require<partial-escape-analysis>,partial-escape-transform,instcombine,simplifycfg,string-intrinsic-specialization,instcombine,simplifycfg' -jeandle-vm-callback-log=%S/Inputs/symbolic-holder.cblog -verify-each %s | FileCheck %s

target datalayout = "e-p:64:64-p1:64:64"
@arrayOopDesc.base_offset_in_bytes.byte = constant i32 16
@arrayOopDesc.base_offset_in_bytes.char = constant i32 16
declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32, i1, i1)
declare i32 @__gxx_personality_v0(...)
declare i32 @jeandle.string_compress(ptr addrspace(1), i32, ptr addrspace(1), i32, i32, i1)
declare void @jeandle.string_inflate(ptr addrspace(1), i32, ptr addrspace(1), i32, i32, i1)

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)

; Array-valued local-holder loads may become virtual aliases during PEA.
; CHECK-LABEL: @holder_compress16(
; CHECK-NOT: jeandle.new_array
; CHECK-NOT: jeandle.new_instance
; CHECK-NOT: call
; CHECK: zext i8 %value to i32
; CHECK: add {{.*}}i32 {{.*}}, 16
; CHECK: ret i32
define i32 @holder_compress16(i8 %value) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %src = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10002 to ptr), i32 16, i32 48, i32 16, i32 100, i1 false, i1 false) to label %next unwind label %u
next:
  %dst = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 16, i32 32, i32 16, i32 100, i1 false, i1 false) to label %work unwind label %u
work:
  %holder = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 100 to ptr), i32 32, i1 false) to label %holder.next unwind label %u
holder.next:
  %sf = getelementptr i8, ptr addrspace(1) %holder, i64 16
  %df = getelementptr i8, ptr addrspace(1) %holder, i64 24
  store atomic ptr addrspace(1) %src, ptr addrspace(1) %sf unordered, align 8
  store atomic ptr addrspace(1) %dst, ptr addrspace(1) %df unordered, align 8
  %indirect.src = load atomic ptr addrspace(1), ptr addrspace(1) %sf unordered, align 8
  %indirect.dst = load atomic ptr addrspace(1), ptr addrspace(1) %df unordered, align 8
  %sp = getelementptr i8, ptr addrspace(1) %src, i64 46
  %wide = zext i8 %value to i16
  store atomic i16 %wide, ptr addrspace(1) %sp unordered, align 2
  %count = call i32 @jeandle.string_compress(ptr addrspace(1) %indirect.src, i32 0, ptr addrspace(1) %indirect.dst, i32 0, i32 16, i1 false)
  %dp = getelementptr i8, ptr addrspace(1) %dst, i64 31
  %cell = load atomic i8, ptr addrspace(1) %dp unordered, align 1
  %result = zext i8 %cell to i32
  %sum = add i32 %result, %count
  ret i32 %sum
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

!java-method-compilation = !{}
