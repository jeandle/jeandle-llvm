; RUN: opt -S -passes='require<partial-escape-analysis>,partial-escape-transform,instcombine,gvn,instcombine,simplifycfg' -jeandle-vm-callback-log=%S/../string-intrinsics/Inputs/layout.cblog -verify-each %s | FileCheck %s --check-prefix=LE
; RUN: sed 's/e-p:64/E-p:64/' %s | opt -S -passes='require<partial-escape-analysis>,partial-escape-transform,instcombine,gvn,instcombine,simplifycfg' -jeandle-vm-callback-log=%S/../string-intrinsics/Inputs/layout.cblog -verify-each | FileCheck %s --check-prefix=BE
;
; Concrete UTF16 byte reads must retain forwarding from Java byte stores.
; On LE the third character fails; on BE the first character already fails.
; The unwritten destination suffix retains its initialized values.
target datalayout = "e-p:64:64-p1:64:64"
declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32, i1, i1)
declare hotspotcc i32 @jeandle.encode_array(ptr addrspace(1), i32, ptr addrspace(1), i32, i32, i1, i1)
declare i32 @personality(...)
; LE-LABEL: @byte_store_forwarding(
; LE-NOT: load atomic
; LE: ret i32 74
; BE-LABEL: @byte_store_forwarding(
; BE-NOT: load atomic
; BE: ret i32 14
define i32 @byte_store_forwarding(ptr addrspace(1) %src) gc "hotspotgc" personality ptr @personality {
entry:
  %dst = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 3, i32 24, i32 16, i32 100, i1 false, i1 false) to label %body unwind label %u
body:
  %p0 = getelementptr i8, ptr addrspace(1) %src, i64 16
  %p1 = getelementptr i8, ptr addrspace(1) %src, i64 17
  %p2 = getelementptr i8, ptr addrspace(1) %src, i64 18
  %p3 = getelementptr i8, ptr addrspace(1) %src, i64 19
  %p4 = getelementptr i8, ptr addrspace(1) %src, i64 20
  %p5 = getelementptr i8, ptr addrspace(1) %src, i64 21
  store atomic i8 65, ptr addrspace(1) %p0 unordered, align 1
  store atomic i8 0, ptr addrspace(1) %p1 unordered, align 1
  store atomic i8 66, ptr addrspace(1) %p2 unordered, align 1
  store atomic i8 0, ptr addrspace(1) %p3 unordered, align 1
  store atomic i8 1, ptr addrspace(1) %p4 unordered, align 1
  store atomic i8 1, ptr addrspace(1) %p5 unordered, align 1
  %d0 = getelementptr i8, ptr addrspace(1) %dst, i64 16
  %d1 = getelementptr i8, ptr addrspace(1) %dst, i64 17
  %d2 = getelementptr i8, ptr addrspace(1) %dst, i64 18
  store atomic i8 7, ptr addrspace(1) %d0 unordered, align 1
  store atomic i8 7, ptr addrspace(1) %d1 unordered, align 1
  store atomic i8 7, ptr addrspace(1) %d2 unordered, align 1
  %r = call hotspotcc i32 @jeandle.encode_array(ptr addrspace(1) %src, i32 0, ptr addrspace(1) %dst, i32 0, i32 3, i1 true, i1 false)
  %b0 = load atomic i8, ptr addrspace(1) %d0 unordered, align 1
  %b2 = load atomic i8, ptr addrspace(1) %d2 unordered, align 1
  %w0 = zext i8 %b0 to i32
  %w2 = zext i8 %b2 to i32
  %sum = add i32 %w0, %w2
  %result = add i32 %sum, %r
  ret i32 %result
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}
!java-method-compilation = !{}
