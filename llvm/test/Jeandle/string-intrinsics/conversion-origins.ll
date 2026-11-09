; RUN: opt -S -passes='string-intrinsic-specialization,instcombine,simplifycfg' -verify-each %s | FileCheck %s
; RUN: opt -S -passes='string-intrinsic-specialization,instcombine,simplifycfg,string-intrinsic-specialization,instcombine,simplifycfg' -verify-each %s | FileCheck %s

target datalayout = "e-p:64:64-p1:64:64"
@arrayOopDesc.base_offset_in_bytes.byte = constant i32 16
@arrayOopDesc.base_offset_in_bytes.char = constant i32 16
@oop_handle_Stable_0 = external global ptr addrspace(1)
declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32, i1, i1)
declare i32 @jeandle.string_compress(ptr addrspace(1), i32, ptr addrspace(1), i32, i32, i1)
declare void @jeandle.string_inflate(ptr addrspace(1), i32, ptr addrspace(1), i32, i32, i1)

; Unrelated Java objects must not change material conversion policy.
; CHECK-LABEL: @unrelated_allocation(
; CHECK: call i32 @jeandle.string_compress
; CHECK: call hotspotcc ptr addrspace(1) @jeandle.new_array
; CHECK: ret ptr addrspace(1)
define ptr addrspace(1) @unrelated_allocation(ptr addrspace(1) %src, ptr addrspace(1) %dst) {
  %r = call i32 @jeandle.string_compress(ptr addrspace(1) %src, i32 0, ptr addrspace(1) %dst, i32 0, i32 16, i1 false)
  %other = call hotspotcc ptr addrspace(1) @jeandle.new_array(ptr null, i32 %r, i32 32, i32 16, i32 100, i1 false, i1 false)
  ret ptr addrspace(1) %other
}

; CHECK-LABEL: @unrelated_handle(
; CHECK: call void @jeandle.string_inflate
; CHECK: ret ptr addrspace(1)
define ptr addrspace(1) @unrelated_handle(ptr addrspace(1) %src, ptr addrspace(1) %dst) {
  %other = load ptr addrspace(1), ptr @oop_handle_Stable_0
  call void @jeandle.string_inflate(ptr addrspace(1) %src, i32 0, ptr addrspace(1) %dst, i32 0, i32 16, i1 false)
  ret ptr addrspace(1) %other
}

; Scalar cells remain useful through ordinary array provenance wrappers.
; CHECK-LABEL: @selected_allocation(
; CHECK: store atomic i16
; CHECK-NOT: call void @jeandle.string_inflate
; CHECK: ret void
define void @selected_allocation(ptr addrspace(1) %src, ptr addrspace(1) %arg, i1 %choose) {
  %allocated = call hotspotcc ptr addrspace(1) @jeandle.new_array(ptr null, i32 16, i32 48, i32 16, i32 100, i1 false, i1 false)
  %dst = select i1 %choose, ptr addrspace(1) %allocated, ptr addrspace(1) %arg
  call void @jeandle.string_inflate(ptr addrspace(1) %src, i32 0, ptr addrspace(1) %dst, i32 0, i32 16, i1 false)
  ret void
}

; CHECK-LABEL: @phi_stable(
; CHECK: load atomic i8
; CHECK-NOT: call i32 @jeandle.string_compress
; CHECK: ret i32
define i32 @phi_stable(ptr addrspace(1) %arg, ptr addrspace(1) %dst, i1 %choose) {
entry:
  br i1 %choose, label %known, label %unknown
known:
  %stable = load ptr addrspace(1), ptr @oop_handle_Stable_0
  br label %join
unknown:
  br label %join
join:
  %src = phi ptr addrspace(1) [ %stable, %known ], [ %arg, %unknown ]
  %r = call i32 @jeandle.string_compress(ptr addrspace(1) %src, i32 0, ptr addrspace(1) %dst, i32 0, i32 16, i1 true)
  ret i32 %r
}

; CHECK-LABEL: @frozen_allocation(
; CHECK: load atomic i16
; CHECK-NOT: call i32 @jeandle.string_compress
; CHECK: ret i32
define i32 @frozen_allocation(ptr addrspace(1) %dst) {
  %allocated = call hotspotcc ptr addrspace(1) @jeandle.new_array(ptr null, i32 16, i32 48, i32 16, i32 100, i1 false, i1 false)
  %src = freeze ptr addrspace(1) %allocated
  %r = call i32 @jeandle.string_compress(ptr addrspace(1) %src, i32 0, ptr addrspace(1) %dst, i32 0, i32 16, i1 false)
  ret i32 %r
}

; A local holder containing material parameters supplies no scalar-cell gain.
; CHECK-LABEL: @holder_material_parameters(
; CHECK: call i32 @jeandle.string_compress
; CHECK: ret i32
define i32 @holder_material_parameters(ptr addrspace(1) %src, ptr addrspace(1) %dst) {
  %holder = call hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr null, i32 24, i1 false)
  %field = getelementptr i8, ptr addrspace(1) %holder, i64 16
  store atomic ptr addrspace(1) %src, ptr addrspace(1) %field unordered, align 8
  %loaded = load atomic ptr addrspace(1), ptr addrspace(1) %field unordered, align 8
  %r = call i32 @jeandle.string_compress(ptr addrspace(1) %loaded, i32 0, ptr addrspace(1) %dst, i32 0, i32 16, i1 false)
  ret i32 %r
}

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
