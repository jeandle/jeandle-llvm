; RUN: opt -S -passes='require<partial-escape-analysis>,partial-escape-transform,instcombine,simplifycfg' -jeandle-vm-callback-log=%S/../string-intrinsics/Inputs/layout.cblog -verify-each %s | FileCheck %s

target datalayout = "e-p:64:64-p1:64:64"
declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32, i1, i1)
declare hotspotcc i32 @jeandle.encode_array(ptr addrspace(1), i32, ptr addrspace(1), i32, i32, i1, i1)
declare i32 @personality(...)

; A symbolic second character is handled without materializing either array.
; The packed destination retains its second byte when that character fails.
; CHECK-LABEL: @symbolic_rollback(
; CHECK-NOT: @jeandle.new_array
; CHECK-NOT: @jeandle.encode_array
; CHECK: icmp ult i16 %value, 128
; CHECK: select
; CHECK: ret i32
define i32 @symbolic_rollback(i16 %value) gc "hotspotgc" personality ptr @personality {
entry:
  %src = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10002 to ptr), i32 2, i32 32, i32 16, i32 100, i1 false, i1 false) to label %alloc unwind label %u
alloc:
  %dst = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 2, i32 32, i32 16, i32 100, i1 false, i1 false) to label %body unwind label %u
body:
  %s0 = getelementptr i8, ptr addrspace(1) %src, i64 16
  %s1 = getelementptr i8, ptr addrspace(1) %src, i64 18
  %d0 = getelementptr i8, ptr addrspace(1) %dst, i64 16
  store atomic i16 65, ptr addrspace(1) %s0 unordered, align 2
  store atomic i16 %value, ptr addrspace(1) %s1 unordered, align 2
  store atomic i16 1799, ptr addrspace(1) %d0 unordered, align 2
  %r = call hotspotcc i32 @jeandle.encode_array(ptr addrspace(1) %src, i32 0, ptr addrspace(1) %dst, i32 0, i32 2, i1 false, i1 true)
  %after = load atomic i16, ptr addrspace(1) %d0 unordered, align 2
  %wide = zext i16 %after to i32
  %result = add i32 %r, %wide
  ret i32 %result
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; A concrete source can feed a virtual destination without materialization.
; CHECK-LABEL: @mixed(
; CHECK-NOT: @jeandle.new_array
; CHECK: load atomic i16
; CHECK-NOT: store atomic
; CHECK-NOT: @jeandle.encode_array
; CHECK: ret i32
define i32 @mixed(ptr addrspace(1) %src) gc "hotspotgc" personality ptr @personality {
entry:
  %dst = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 2, i32 32, i32 16, i32 100, i1 false, i1 false) to label %body unwind label %u
body:
  %d = getelementptr i8, ptr addrspace(1) %dst, i64 17
  store atomic i8 7, ptr addrspace(1) %d unordered, align 1
  %r = call hotspotcc i32 @jeandle.encode_array(ptr addrspace(1) %src, i32 0, ptr addrspace(1) %dst, i32 0, i32 2, i1 false, i1 false)
  ret i32 %r
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

!java-method-compilation = !{}
