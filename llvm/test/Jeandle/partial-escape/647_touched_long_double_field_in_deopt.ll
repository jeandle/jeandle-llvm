; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; A never-escaping VO with TOUCHED long/double fields is still described
; by a ScalarValueType descriptor in the deopt bundle. The emit carries ONE
; typed wire pair per touched field regardless of width:
;   int    field: enc(offset, LocalType, T_INT)    + i32 value   (1 slot)
;   long   field: enc(offset, LocalType, T_LONG)   + i64 value   (parse expands to 2 field_values slots)
;   double field: enc(offset, LocalType, T_DOUBLE) + f64 value   (parse expands to 2 field_values slots)
; The HotSpot parser's fill_one_scope_value T_LONG/T_DOUBLE branch produces
; the two ScopeValue slots (ConstantIntValue(0) hi placeholder +
; ConstantLongValue/ConstantDoubleValue lo) that reassign_fields_by_klass
; consumes (it reads two slots per T_LONG/T_DOUBLE layout field and uses the
; lo slot's full 64-bit intptr_t on LP64). This test pins the wire side; the
; parse/realloc side is exercised end-to-end by the jtreg deopt suite.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(i32, i64, double)
declare i32 @__gxx_personality_v0(...)

define void @never_escape_vo_long_double_field(i32 %x, i64 %y, double %z)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 32, i1 false)
       to label %n unwind label %u
n:
  %s1 = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  %s2 = getelementptr inbounds i8, ptr addrspace(1) %o, i64 16
  %s3 = getelementptr inbounds i8, ptr addrspace(1) %o, i64 24
  store atomic i32 %x, ptr addrspace(1) %s1 unordered, align 4
  store atomic i64 %y, ptr addrspace(1) %s2 unordered, align 8
  store atomic double %z, ptr addrspace(1) %s3 unordered, align 8
  %v1 = load atomic i32, ptr addrspace(1) %s1 unordered, align 4
  %v2 = load atomic i64, ptr addrspace(1) %s2 unordered, align 8
  %v3 = load atomic double, ptr addrspace(1) %s3 unordered, align 8
  ; Only the scalarized field values reach @sink; %o lives solely in the
  ; deopt bundle. The bundle carries a duplicated-BCI marker (i32 99, i32 99)
  ; then one locals entry: enc(LocalType, index=0, T_OBJECT)=12 followed by
  ; the OrigAlloc pointer %o.
  call void @sink(i32 %v1, i64 %v2, double %v3)
       [ "deopt"(i32 99, i32 99, i64 12, ptr addrspace(1) %o) ]
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @never_escape_vo_long_double_field
; The OrigAlloc invoke is eliminated (NeverEscapes).
; CHECK-NOT: jeandle.new_instance
; The surviving sink call still carries a "deopt" bundle, but the slot that
; held OrigAlloc is now a VORefType reference, and a ScalarValueType VO
; descriptor (klass 12345 + the three field values, including the touched
; long and double fields) is appended after the duplicated-BCI marker.
;
; VORefLocalType slot encoding (vo_id=0): (0<<32)|(8<<16)|12 = 524300
; CHECK: call void @sink(i32 %x, i64 %y, double %z)
; CHECK-SAME: [ "deopt"(
; duplicated-BCI marker preserved.
; CHECK-SAME: i32 99, i32 99,
; ScalarValueType VO descriptor header (vo_id=0): (0<<32)|(4<<16)|12 = 262156
; CHECK-SAME: i64 262156, i64 12345, i32 3,
; field 0 (offset 8, LocalType/T_INT): (8<<32)|10 = 34359738378 -> value %x
; CHECK-SAME: i64 34359738378, i32 %x,
; field 1 (offset 16, LocalType/T_LONG): (16<<32)|11 = 68719476747 -> value %y
; (One typed wire pair carries the full i64; the parse side expands it to two
; ScopeValue slots.)
; CHECK-SAME: i64 68719476747, i64 %y,
; field 2 (offset 24, LocalType/T_DOUBLE): (24<<32)|7 = 103079215111 -> value %z
; CHECK-SAME: i64 103079215111, double %z,
; the OrigAlloc locals slot is replaced by a VORefLocalType reference
; (enc 524300) followed by vo_id i32 0.
; CHECK-SAME: i64 524300, i32 0) ]
; The eliminated OrigAlloc must not appear (no poison, no %o) in the bundle.
; CHECK-NOT: addrspace(1) %o

!java-method-compilation = !{}
