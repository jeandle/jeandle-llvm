; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" -jeandle-vm-callback-log=%S/Inputs/653_array_long_deopt.cblog %s | FileCheck %s

; Array VO deopt descriptor (long[]). A never-escaping long[] of length 2.
; Element 0 is touched (the i64 argument %v); element 1 is default 0. Each
; long element is one typed wire pair: enc(offset, LocalType, T_LONG) + the i64
; value. The HotSpot parser expands each pair to two ScopeValue slots, so
; field_count == length still holds: a length-2 long[] yields 2 wire pairs ->
; 4 ScopeValue slots -> len = 4/2 = 2.

declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32, i1, i1)
declare void @sink(i64)
declare i32 @__gxx_personality_v0(...)

define void @array_long_deopt(i64 %v) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %arr = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
            ptr inttoptr (i64 53003 to ptr), i32 2, i32 32, i32 16, i32 1048576, i1 false, i1 false)
         to label %n unwind label %u
n:
  ; long[] base 16, scale 8: index 0 @ byte offset 16.
  %base = getelementptr inbounds i8, ptr addrspace(1) %arr, i32 16
  %p0 = getelementptr inbounds i64, ptr addrspace(1) %base, i64 0
  store atomic i64 %v, ptr addrspace(1) %p0 unordered, align 8
  %v0 = load atomic i64, ptr addrspace(1) %p0 unordered, align 8
  ; %arr lives ONLY in the deopt bundle.
  call void @sink(i64 %v0)
       [ "deopt"(i32 99, i32 99, i64 12, ptr addrspace(1) %arr) ]
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @array_long_deopt
; CHECK-NOT: jeandle.new_array
; The load folds to the stored value.
; CHECK: call void @sink(i64 %v)
; CHECK-SAME: [ "deopt"(
; CHECK-SAME: i32 99, i32 99,
; ScalarValueType ARRAY descriptor header (vo_id=0, T_ARRAY=13): 262157
; CHECK-SAME: i64 262157, i64 53003, i32 2,
; elem 0 @ offset 16 (touched, %v), LocalType/T_LONG (one wire entry):
;   (16<<32)|11 = 68719476747
; CHECK-SAME: i64 68719476747, i64 %v,
; elem 1 @ offset 24 (untouched default 0), LocalType/T_LONG:
;   (24<<32)|11 = 103079215115
; CHECK-SAME: i64 103079215115, i64 0,
; the OrigAlloc locals slot -> VORefLocalType (vo_id=0): 524300
; CHECK-SAME: i64 524300, i32 0) ]
; CHECK-NOT: addrspace(1) %arr

!java-method-compilation = !{}
