; RUN: opt -S -passes='require<partial-escape-analysis>,partial-escape-transform,instcombine,simplifycfg' -jeandle-vm-callback-log=%S/../string-intrinsics/Inputs/layout.cblog -verify-each %s | FileCheck %s

target datalayout = "e-p:64:64-p1:64:64"
declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32, i1, i1)
declare hotspotcc i32 @jeandle.encode_array(ptr addrspace(1), i32, ptr addrspace(1), i32, i32, i1, i1)
declare hotspotcc i32 @jeandle.count_positives(ptr addrspace(1), i32, i32)
declare i32 @personality(...)

; CHECK-LABEL: @scan_virtual(
; CHECK-NOT: @jeandle.new_array
; CHECK-NOT: @jeandle.count_positives
; CHECK: ret i32 1
define i32 @scan_virtual() gc "hotspotgc" personality ptr @personality {
entry:
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 4, i32 32, i32 16, i32 100, i1 false, i1 false) to label %body unwind label %u
body:
  %p = getelementptr i8, ptr addrspace(1) %a, i64 17
  store atomic i8 -1, ptr addrspace(1) %p unordered, align 1
  %r = call hotspotcc i32 @jeandle.count_positives(ptr addrspace(1) %a, i32 0, i32 4)
  ret i32 %r
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: @encode_virtual_prefix(
; CHECK-NOT: @jeandle.new_array
; CHECK-NOT: @jeandle.encode_array
; CHECK: ret i32 757
define i32 @encode_virtual_prefix() gc "hotspotgc" personality ptr @personality {
entry:
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10002 to ptr), i32 2, i32 32, i32 16, i32 100, i1 false, i1 false) to label %alloc unwind label %u
alloc:
  %b = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 2, i32 32, i32 16, i32 100, i1 false, i1 false) to label %body unwind label %u
body:
  %ap = getelementptr i8, ptr addrspace(1) %a, i64 16
  %ap1 = getelementptr i8, ptr addrspace(1) %a, i64 18
  store atomic i16 65, ptr addrspace(1) %ap unordered, align 2
  store atomic i16 256, ptr addrspace(1) %ap1 unordered, align 2
  %bp = getelementptr i8, ptr addrspace(1) %b, i64 16
  %bp1 = getelementptr i8, ptr addrspace(1) %b, i64 17
  store atomic i8 7, ptr addrspace(1) %bp1 unordered, align 1
  %r = call hotspotcc i32 @jeandle.encode_array(ptr addrspace(1) %a, i32 0, ptr addrspace(1) %b, i32 0, i32 2, i1 false, i1 false)
  %first = load atomic i8, ptr addrspace(1) %bp unordered, align 1
  %second = load atomic i8, ptr addrspace(1) %bp1 unordered, align 1
  %x = zext i8 %first to i32
  %y = zext i8 %second to i32
  %r100 = mul i32 %r, 100
  %x10 = mul i32 %x, 10
  %sum = add i32 %r100, %x10
  %result = add i32 %sum, %y
  ret i32 %result
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: @encode_bytes_ascii(
; CHECK-NOT: @jeandle.new_array
; CHECK-NOT: @jeandle.encode_array
; CHECK: ret i32 737
define i32 @encode_bytes_ascii() gc "hotspotgc" personality ptr @personality {
entry:
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 4, i32 32, i32 16, i32 100, i1 false, i1 false) to label %alloc unwind label %u
alloc:
  %b = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 2, i32 32, i32 16, i32 100, i1 false, i1 false) to label %body unwind label %u
body:
  %ap = getelementptr i8, ptr addrspace(1) %a, i64 16
  %ap1 = getelementptr i8, ptr addrspace(1) %a, i64 17
  store atomic i8 63, ptr addrspace(1) %ap unordered, align 1
  store atomic i8 0, ptr addrspace(1) %ap1 unordered, align 1
  %ap2 = getelementptr i8, ptr addrspace(1) %a, i64 18
  store atomic i8 -128, ptr addrspace(1) %ap2 unordered, align 1
  %bp = getelementptr i8, ptr addrspace(1) %b, i64 16
  %bp1 = getelementptr i8, ptr addrspace(1) %b, i64 17
  store atomic i8 7, ptr addrspace(1) %bp1 unordered, align 1
  %r = call hotspotcc i32 @jeandle.encode_array(ptr addrspace(1) %a, i32 0, ptr addrspace(1) %b, i32 0, i32 2, i1 true, i1 true)
  %first = load atomic i8, ptr addrspace(1) %bp unordered, align 1
  %second = load atomic i8, ptr addrspace(1) %bp1 unordered, align 1
  %x = zext i8 %first to i32
  %y = zext i8 %second to i32
  %r100 = mul i32 %r, 100
  %x10 = mul i32 %x, 10
  %sum = add i32 %r100, %x10
  %result = add i32 %sum, %y
  ret i32 %result
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

!java-method-compilation = !{}
