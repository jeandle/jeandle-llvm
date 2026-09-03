; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Sub-int (i1/i8/i16) VO descriptor field values whose value is NOT a
; constant must be widened to i32 before entering the deopt bundle. The
; field's wire encoding is T_INT (Java boolean/byte/char/short fields occupy
; int slots), and the HotSpot stackmap parser resolves every T_INT location
; as a 4-byte slot (Location::new_stk_loc truncates the byte offset to a
; 4-byte boundary). A raw sub-int value would be recorded in a sub-int
; stackmap location and silently reconstructed from unrelated bytes on
; deopt. The analyzer therefore synthesizes an unparented `pea.deopt.widen`
; zext (spliced before the safepoint) so the stackmap records an int-width
; location. Constants stay as-is: stackmap constants are already full-width.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(i8, i16, i1)
declare i32 @__gxx_personality_v0(...)

define void @subint_phi_fields_widened(i8 %a, i8 %b, i16 %c, i16 %d, i1 %cond)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 74801 to ptr), i32 32, i1 false)
       to label %n unwind label %u
n:
  br i1 %cond, label %then, label %else
then:
  %s1t = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  store atomic i8 %a, ptr addrspace(1) %s1t unordered, align 1
  %s2t = getelementptr inbounds i8, ptr addrspace(1) %o, i64 16
  store atomic i16 %c, ptr addrspace(1) %s2t unordered, align 2
  br label %merge
else:
  %s1e = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  store atomic i8 %b, ptr addrspace(1) %s1e unordered, align 1
  %s2e = getelementptr inbounds i8, ptr addrspace(1) %o, i64 16
  store atomic i16 %d, ptr addrspace(1) %s2e unordered, align 2
  br label %merge
merge:
  ; The i8/i16/i1 fields merge into field PHIs; %o lives solely in the
  ; deopt bundle.
  call void @sink(i8 0, i16 0, i1 false)
       [ "deopt"(i32 99, i32 99, i64 12, ptr addrspace(1) %o) ]
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @subint_phi_fields_widened
; CHECK-NOT: jeandle.new_instance
; The two field PHIs are each widened to i32 for the descriptor.
; CHECK: %[[W1:.*]] = zext i8 %pea.field.phi{{[0-9]*}} to i32
; CHECK: %[[W2:.*]] = zext i16 %pea.field.phi{{[0-9]*}} to i32
; CHECK: call void @sink(i8 0, i16 0, i1 false)
; CHECK-SAME: [ "deopt"(i32 99, i32 99,
; ScalarValueType VO descriptor header (vo_id=0): (0<<32)|(4<<16)|12 = 262156
; CHECK-SAME: i64 262156, i64 74801, i32 2,
; field 0 (offset 8, LocalType/T_INT): (8<<32)|10 = 34359738378 -> widened i32
; CHECK-SAME: i64 34359738378, i32 %[[W1]],
; field 1 (offset 16, LocalType/T_INT): (16<<32)|10 = 68719476746 -> widened i32
; CHECK-SAME: i64 68719476746, i32 %[[W2]],
; CHECK-SAME: i64 524300, i32 0) ]
; No raw sub-int value may reach the bundle.
; CHECK-NOT: i8 %a
; CHECK-NOT: i16 %c

define void @subint_constants_not_widened()
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 74802 to ptr), i32 32, i1 false)
       to label %n unwind label %u
n:
  %s1 = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  store atomic i8 42, ptr addrspace(1) %s1 unordered, align 1
  %s2 = getelementptr inbounds i8, ptr addrspace(1) %o, i64 16
  store atomic i16 1000, ptr addrspace(1) %s2 unordered, align 2
  ; %o lives solely in the deopt bundle.
  call void @sink(i8 0, i16 0, i1 false)
       [ "deopt"(i32 99, i32 99, i64 12, ptr addrspace(1) %o) ]
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @subint_constants_not_widened
; CHECK-NOT: jeandle.new_instance
; Constants are already full-width in the stackmap constant pool: they are
; emitted directly, with no pea.deopt.widen zext.
; CHECK-NOT: pea.deopt.widen
; CHECK: call void @sink(i8 0, i16 0, i1 false)
; CHECK-SAME: [ "deopt"(i32 99, i32 99,
; CHECK-SAME: i64 262156, i64 74802, i32 2,
; field 0 (offset 8, LocalType/T_INT): 34359738378 -> constant i8 42
; CHECK-SAME: i64 34359738378, i8 42,
; field 1 (offset 16, LocalType/T_INT): 68719476746 -> constant i16 1000
; CHECK-SAME: i64 68719476746, i16 1000,
; CHECK-SAME: i64 524300, i32 0) ]

!java-method-compilation = !{}
