; RUN: opt -S -passes='string-intrinsic-specialization,require<partial-escape-analysis>,partial-escape-transform,instcombine,simplifycfg' -jeandle-vm-callback-log=%S/Inputs/layout.cblog -verify-each %s | FileCheck %s --check-prefix=LE
; RUN: sed 's/e-p:64/E-p:64/' %s | opt -S -passes='string-intrinsic-specialization,require<partial-escape-analysis>,partial-escape-transform,instcombine,simplifycfg' -jeandle-vm-callback-log=%S/Inputs/layout.cblog -verify-each | FileCheck %s --check-prefix=BE

target datalayout = "e-p:64:64-p1:64:64"
declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32, i1, i1)
declare i32 @__gxx_personality_v0(...)
declare void @jeandle.string_copy_utf16(ptr addrspace(1), i32, ptr addrspace(1), i32, i32, i1)

; Byte halves remain symbolic through virtualization. Native order decides
; which half occupies the high bits; char[] still stores one i16 cell.

; LE-LABEL: @symbolic_halves(
; LE-NOT: jeandle.new_array
; LE-NOT: call
; LE: %[[HI:.*]] = zext i8 %second to i16
; LE: %[[SHIFT:.*]] = shl nuw i16 %[[HI]], 8
; LE: %[[LO:.*]] = zext i8 %first to i16
; LE: %[[WORD:.*]] = or disjoint i16 %[[SHIFT]], %[[LO]]
; LE: %[[RESULT:.*]] = zext i16 %[[WORD]] to i32
; LE: ret i32 %[[RESULT]]
; BE-LABEL: @symbolic_halves(
; BE-NOT: jeandle.new_array
; BE-NOT: call
; BE: %[[HI:.*]] = zext i8 %first to i16
; BE: %[[SHIFT:.*]] = shl nuw i16 %[[HI]], 8
; BE: %[[LO:.*]] = zext i8 %second to i16
; BE: %[[WORD:.*]] = or disjoint i16 %[[SHIFT]], %[[LO]]
; BE: %[[RESULT:.*]] = zext i16 %[[WORD]] to i32
; BE: ret i32 %[[RESULT]]
 define i32 @symbolic_halves(i8 %first, i8 %second) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
 %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 2, i32 24, i32 16, i32 100, i1 false, i1 false) to label %next unwind label %u
next:
 %b = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10002 to ptr), i32 1, i32 24, i32 16, i32 100, i1 false, i1 false) to label %work unwind label %u
work:
 %p0 = getelementptr i8, ptr addrspace(1) %a, i64 16
 %p1 = getelementptr i8, ptr addrspace(1) %a, i64 17
 store atomic i8 %first, ptr addrspace(1) %p0 unordered, align 1
 store atomic i8 %second, ptr addrspace(1) %p1 unordered, align 1
 call void @jeandle.string_copy_utf16(ptr addrspace(1) %a, i32 0, ptr addrspace(1) %b, i32 0, i32 1, i1 true)
 %bp = getelementptr i8, ptr addrspace(1) %b, i64 16
 %v = load atomic i16, ptr addrspace(1) %bp unordered, align 2
 %r = zext i16 %v to i32
 ret i32 %r
u:
 %lp = landingpad i64 cleanup
 resume i64 %lp
}
!java-method-compilation = !{}
