; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" -jeandle-vm-callback-log=%S/Inputs/651_array_int_deopt.cblog %s | FileCheck %s

; Array VO deopt descriptor (int[]). A never-escaping int[] of length 4 whose
; pointer lives ONLY in the "deopt" operand bundle of a safepoint call.
; Elements at index 1 and 3 are touched (100, 400); indices 0 and 2 are
; untouched (default 0). The VO descriptor MUST carry field_count = ArrayLength
; (4) and emit ALL elements in offset order, synthesizing i32 0 defaults for
; the untouched slots: HotSpot's realloc_objects derives the array length from
; field_values.size() (typeArray: len = field_size()/type2size), so emitting
; only touched elements would miscompile the length. The header basicType is
; T_ARRAY (13), NOT T_OBJECT — the parse side dispatches on it to know it is
; rebuilding an array (uniform elements indexed by offset) rather than walking
; an InstanceKlass field layout.

declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32, i1, i1)
declare void @sink(i32, i32)
declare i32 @__gxx_personality_v0(...)

define void @array_int_deopt() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %arr = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
            ptr inttoptr (i64 51001 to ptr), i32 4, i32 32, i32 16, i32 1048576, i1 false, i1 false)
         to label %n unwind label %u
n:
  ; int[] base 16, scale 4: index 1 @ byte offset 20, index 3 @ offset 28.
  %base = getelementptr inbounds i8, ptr addrspace(1) %arr, i32 16
  %p1 = getelementptr inbounds i32, ptr addrspace(1) %base, i64 1
  %p3 = getelementptr inbounds i32, ptr addrspace(1) %base, i64 3
  store atomic i32 100, ptr addrspace(1) %p1 unordered, align 4
  store atomic i32 400, ptr addrspace(1) %p3 unordered, align 4
  %v1 = load atomic i32, ptr addrspace(1) %p1 unordered, align 4
  %v3 = load atomic i32, ptr addrspace(1) %p3 unordered, align 4
  ; %arr lives ONLY in the deopt bundle (never passed to @sink). The bundle
  ; carries the duplicated-BCI marker (i32 99, i32 99) then one locals entry:
  ; enc(LocalType, index=0, T_OBJECT)=12 followed by the OrigAlloc %arr.
  call void @sink(i32 %v1, i32 %v3)
       [ "deopt"(i32 99, i32 99, i64 12, ptr addrspace(1) %arr) ]
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @array_int_deopt
; The OrigAlloc (new_array) is eliminated — the array never escapes.
; CHECK-NOT: jeandle.new_array
; The loads fold to the stored constants.
; CHECK: call void @sink(i32 100, i32 400)
; CHECK-SAME: [ "deopt"(
; duplicated-BCI marker preserved.
; CHECK-SAME: i32 99, i32 99,
; ScalarValueType ARRAY descriptor header (vo_id=0, ScalarValueType=4, T_ARRAY=13):
;   (0<<32)|(4<<16)|13 = 262157
; CHECK-SAME: i64 262157, i64 51001, i32 4,
; elem 0 @ offset 16 (untouched default 0), LocalType/T_INT:
;   (16<<32)|10 = 68719476746
; CHECK-SAME: i64 68719476746, i32 0,
; elem 1 @ offset 20 (touched, 100), LocalType/T_INT:
;   (20<<32)|10 = 85899345930
; CHECK-SAME: i64 85899345930, i32 100,
; elem 2 @ offset 24 (untouched default 0), LocalType/T_INT:
;   (24<<32)|10 = 103079215114
; CHECK-SAME: i64 103079215114, i32 0,
; elem 3 @ offset 28 (touched, 400), LocalType/T_INT:
;   (28<<32)|10 = 120259084298
; CHECK-SAME: i64 120259084298, i32 400,
; the OrigAlloc locals slot is replaced by a VORefLocalType reference
; (vo_id=0): (0<<32)|(8<<16)|12 = 524300
; CHECK-SAME: i64 524300, i32 0) ]
; The eliminated OrigAlloc must not appear in the bundle.
; CHECK-NOT: addrspace(1) %arr

!java-method-compilation = !{}
