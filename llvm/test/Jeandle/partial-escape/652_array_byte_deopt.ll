; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" -jeandle-vm-callback-log=%S/Inputs/652_array_byte_deopt.cblog %s | FileCheck %s

; Array VO deopt descriptor (byte[]). A never-escaping byte[] of length 4.
; Elements at index 0 and 2 are touched (42, 99); indices 1 and 3 are default.
; Each byte element is emitted as a normal T_INT single-slot entry (the JVM
; computational type of byte is T_INT): we deliberately SKIP the JVMCI
; JavaKind.Illegal packed-write micro-optimization that packs adjacent byte/
; boolean slots — emit one T_INT entry per element so field_count == length
; and HotSpot's typeArray length derivation (field_size()/type2size) is exact.

declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32, i1, i1)
declare void @sink(i8, i8)
declare i32 @__gxx_personality_v0(...)

define void @array_byte_deopt() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %arr = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
            ptr inttoptr (i64 52002 to ptr), i32 4, i32 32, i32 16, i32 1048576, i1 false, i1 false)
         to label %n unwind label %u
n:
  ; byte[] base 16, scale 1: index 0 @ byte offset 16, index 2 @ offset 18.
  %base = getelementptr inbounds i8, ptr addrspace(1) %arr, i32 16
  %p0 = getelementptr inbounds i8, ptr addrspace(1) %base, i64 0
  %p2 = getelementptr inbounds i8, ptr addrspace(1) %base, i64 2
  store atomic i8 42, ptr addrspace(1) %p0 unordered, align 1
  store atomic i8 99, ptr addrspace(1) %p2 unordered, align 1
  %v0 = load atomic i8, ptr addrspace(1) %p0 unordered, align 1
  %v2 = load atomic i8, ptr addrspace(1) %p2 unordered, align 1
  ; %arr lives ONLY in the deopt bundle.
  call void @sink(i8 %v0, i8 %v2)
       [ "deopt"(i32 99, i32 99, i64 12, ptr addrspace(1) %arr) ]
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @array_byte_deopt
; CHECK-NOT: jeandle.new_array
; The loads fold to the stored constants.
; CHECK: call void @sink(i8 42, i8 99)
; CHECK-SAME: [ "deopt"(
; CHECK-SAME: i32 99, i32 99,
; ScalarValueType ARRAY descriptor header (vo_id=0, T_ARRAY=13): 262157
; CHECK-SAME: i64 262157, i64 52002, i32 4,
; elem 0 @ offset 16 (touched, 42), LocalType/T_INT (byte computational type):
;   (16<<32)|10 = 68719476746
; CHECK-SAME: i64 68719476746, i8 42,
; elem 1 @ offset 17 (untouched default 0), LocalType/T_INT:
;   (17<<32)|10 = 73014444042
; CHECK-SAME: i64 73014444042, i8 0,
; elem 2 @ offset 18 (touched, 99), LocalType/T_INT:
;   (18<<32)|10 = 77309411338
; CHECK-SAME: i64 77309411338, i8 99,
; elem 3 @ offset 19 (untouched default 0), LocalType/T_INT:
;   (19<<32)|10 = 81604378634
; CHECK-SAME: i64 81604378634, i8 0,
; the OrigAlloc locals slot -> VORefLocalType (vo_id=0): 524300
; CHECK-SAME: i64 524300, i32 0) ]
; CHECK-NOT: addrspace(1) %arr

!java-method-compilation = !{}
