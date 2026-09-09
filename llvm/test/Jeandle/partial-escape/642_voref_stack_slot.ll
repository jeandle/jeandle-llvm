; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Sibling of 640_never_escape_vo_in_deopt_bundle.ll, but the never-escaping VO
; is referenced from an EXPRESSION-STACK slot of the "deopt" bundle, not a
; locals slot. This drives the StackType branch of the VORef slot rewrite
; (PartialEscapeTransform.cpp whole-pool rewrite: a StackType slot becomes
; VORefStackType, not VORefLocalType). The HotSpot parser routes a VORef by
; encoding type to the correct
; interpreter array (locals vs expression stack), so the two must stay distinct
; (structural guarantee).
;
; Bundle layout (hand-crafted, as in 640): duplicated-BCI marker (i32 99, 99),
; then ONE stack entry: enc(StackType, index=0, T_OBJECT) = (0<<32)|(1<<16)|12
; = 65548, followed by the OrigAlloc pointer %o.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(i32, i32)
declare i32 @__gxx_personality_v0(...)

define void @never_escape_vo_stack_slot(i32 %a, i32 %b) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 24, i1 false)
       to label %n unwind label %u
n:
  %s1 = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  %s2 = getelementptr inbounds i8, ptr addrspace(1) %o, i64 16
  store atomic i32 %a, ptr addrspace(1) %s1 unordered, align 4
  store atomic i32 %b, ptr addrspace(1) %s2 unordered, align 4
  %v1 = load atomic i32, ptr addrspace(1) %s1 unordered, align 4
  %v2 = load atomic i32, ptr addrspace(1) %s2 unordered, align 4
  ; %o lives solely in the deopt bundle, in an EXPRESSION-STACK slot.
  call void @sink(i32 %v1, i32 %v2)
       [ "deopt"(i32 99, i32 99, i64 65548, ptr addrspace(1) %o) ]
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @never_escape_vo_stack_slot
; The OrigAlloc invoke is eliminated (NeverEscapes).
; CHECK-NOT: jeandle.new_instance
; CHECK: call void @sink(i32 %a, i32 %b)
; CHECK-SAME: [ "deopt"(
; duplicated-BCI marker preserved.
; CHECK-SAME: i32 99, i32 99,
; ScalarValueType VO descriptor header (vo_id=0): (0<<32)|(4<<16)|12 = 262156
; CHECK-SAME: i64 262156, i64 12345, i32 2,
; field 0 (offset 8, LocalType/T_INT): (8<<32)|10 = 34359738378 -> value %a
; CHECK-SAME: i64 34359738378, i32 %a,
; field 1 (offset 16, LocalType/T_INT): (16<<32)|10 = 68719476746 -> value %b
; CHECK-SAME: i64 68719476746, i32 %b,
; the OrigAlloc EXPRESSION-STACK slot is replaced by a VORefStackType reference
; (vo_id=0): (0<<32)|(9<<16)|12 = 589836, followed by vo_id i32 0.
; CHECK-SAME: i64 589836, i32 0) ]
; The eliminated OrigAlloc must not appear in the bundle.
; CHECK-NOT: addrspace(1) %o

!java-method-compilation = !{}
