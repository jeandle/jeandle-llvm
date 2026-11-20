; RUN: opt -S -passes='character-intrinsic-specialization,instcombine,simplifycfg' -verify-each %s | FileCheck %s

target datalayout = "E-p:64:64-p1:64:64"
@arrayOopDesc.base_offset_in_bytes.byte = constant i32 16
declare hotspotcc i32 @jeandle.encode_array(ptr addrspace(1), i32, ptr addrspace(1), i32, i32, i1, i1)

; The high byte is the first byte in big endian. The stored low byte must
; come from the second load, with two separate unordered byte accesses.
; CHECK-LABEL: @encode(
; CHECK: [[HIGH:%.*]] = load atomic i8, ptr addrspace(1) {{.*}} unordered, align 1
; CHECK: icmp eq i8 [[HIGH]], 0
; CHECK: br i1
; CHECK: [[LOW:%.*]] = load atomic i8, ptr addrspace(1) {{.*}} unordered, align 1
; CHECK: store atomic i8 [[LOW]], ptr addrspace(1) {{.*}} unordered, align 1
; CHECK-NOT: @jeandle.encode_array
; CHECK: ret i32
define i32 @encode(ptr addrspace(1) %src, ptr addrspace(1) %dst) {
  %r = call hotspotcc i32 @jeandle.encode_array(ptr addrspace(1) %src, i32 0, ptr addrspace(1) %dst, i32 0, i32 1, i1 true, i1 false)
  ret i32 %r
}
