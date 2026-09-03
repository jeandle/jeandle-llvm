; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; GC-liveness: a virtual object whose field holds a reference to a REAL
; (non-virtual) oop must still be describable. Here %obj (klass 100) has a
; scalar int field at offset 8 and a reference field at offset 16 whose value
; is %ext -- an external/parameter wide oop (addrspace 1), NOT a virtual VO.
; %obj never escapes, so it is virtual at the deopt safepoint and must be
; described; its offset-16 field value is the live oop %ext, which RS4GC keeps
; GC-live/relocatable as a deopt-bundle operand and HotSpot's
; fill_one_scope_value T_OBJECT non-constant branch consumes as
; LocationValue(Location::oop).
;
; planFields records a Scalar cell for a wide-oop (addrspace 1) field value
; that is not a non-null constant; narrow-oop (addrspace 3) and non-null
; constant oop fields still bail (CompressedOops deferred;
; fill_one_scope_value ShouldNotReachHere on constant oops). Regression
; guard: bailing a reference-typed field whose value does not resolve to a
; virtual VO (ref-to-non-VO -> Cell::Bad) would make %obj wholly
; undescribable and force it to materialize at the safepoint.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(i32)
declare i32 @__gxx_personality_v0(...)

define void @field_holds_external_oop(i32 %x, ptr addrspace(1) %ext) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %obj = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 100 to ptr), i32 24, i1 false)
         to label %body unwind label %u
body:
  ; obj: offset 8 = int %x, offset 16 = ref %ext (external wide oop, not a VO)
  %of1 = getelementptr inbounds i8, ptr addrspace(1) %obj, i64 8
  %of2 = getelementptr inbounds i8, ptr addrspace(1) %obj, i64 16
  store atomic i32 %x, ptr addrspace(1) %of1 unordered, align 4
  store atomic ptr addrspace(1) %ext, ptr addrspace(1) %of2 unordered, align 8
  %ox = load atomic i32, ptr addrspace(1) %of1 unordered, align 4
  ; %obj is a root (its OrigAlloc is a bundle operand). %ext is described as
  ; obj's field value (a live oop the GC must keep relocatable).
  call void @sink(i32 %ox)
       [ "deopt"(i32 99, i32 99, i64 12, ptr addrspace(1) %obj) ]
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; vo-id: %obj=0.
; CHECK-LABEL: define void @field_holds_external_oop
; %obj is eliminated (NeverEscapes).
; CHECK-NOT: jeandle.new_instance
; CHECK: call void @sink(i32 %x)
; CHECK-SAME: [ "deopt"(
; CHECK-SAME: i32 99, i32 99,
; descriptor obj (vo_id=0, ScalarValueType, T_OBJECT): (0<<32)|(4<<16)|12 = 262156
; CHECK-SAME: i64 262156, i64 100, i32 2,
; obj field 0 (offset 8, LocalType/T_INT): (8<<32)|10 = 34359738378 -> value %x
; CHECK-SAME: i64 34359738378, i32 %x,
; obj field 1 (offset 16, LocalType/T_OBJECT): (16<<32)|12 = 68719476748
;   -> value is the live oop %ext
; CHECK-SAME: i64 68719476748, ptr addrspace(1) %ext,
; %obj's locals slot rewritten to VORef(vo_id=0): (0<<32)|(8<<16)|12 = 524300
; CHECK-SAME: i64 524300, i32 0) ]
; The eliminated OrigAlloc must not appear in the bundle.
; CHECK-NOT: addrspace(1) %obj

!java-method-compilation = !{}
