; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; GC-liveness (MaterializedRef): %outer (klass 100) has a scalar int field at
; offset 8 and a reference field at offset 16 that initially holds VO %inner
; (klass 200). %inner then ESCAPES through the unknown call @escape, so it is
; materialized; %outer's offset-16 field state becomes MaterializedRef holding
; %inner's OrigAlloc (the live, now-materialized oop). %outer itself never
; escapes, so it is virtual at the deopt safepoint and must be described; its
; offset-16 field value is the live oop %inner, which RS4GC keeps relocatable.
;
; planFields flattens a describable MaterializedRef (wide oop, non-null,
; non-constant) to a Scalar live-oop field. Bailing MaterializedRef fields
; (Cell::Bad) would leave %outer undescribable and force it to materialize
; too.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(i32)
declare void @escape(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @field_holds_materialized_vo(i32 %x, i32 %y) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %outer = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
              ptr inttoptr (i64 100 to ptr), i32 24, i1 false)
           to label %alloc_inner unwind label %u
alloc_inner:
  %inner = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
              ptr inttoptr (i64 200 to ptr), i32 16, i1 false)
           to label %body unwind label %u
body:
  ; outer: offset 8 = int %x, offset 16 = ref %inner
  %of1 = getelementptr inbounds i8, ptr addrspace(1) %outer, i64 8
  %of2 = getelementptr inbounds i8, ptr addrspace(1) %outer, i64 16
  store atomic i32 %x, ptr addrspace(1) %of1 unordered, align 4
  store atomic ptr addrspace(1) %inner, ptr addrspace(1) %of2 unordered, align 8
  ; inner: offset 8 = int %y
  %if1 = getelementptr inbounds i8, ptr addrspace(1) %inner, i64 8
  store atomic i32 %y, ptr addrspace(1) %if1 unordered, align 4
  ; %inner escapes through the unknown call -> materialized. %outer's offset-16
  ; field state becomes MaterializedRef(%inner's OrigAlloc).
  call void @escape(ptr addrspace(1) %inner)
  %ox = load atomic i32, ptr addrspace(1) %of1 unordered, align 4
  ; %outer is a root; its offset-16 field is the live (materialized) oop %inner.
  call void @sink(i32 %ox)
       [ "deopt"(i32 99, i32 99, i64 12, ptr addrspace(1) %outer) ]
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; vo-ids: %outer=0, %inner=1. %inner is materialized (kept); %outer is
; eliminated and described.
; CHECK-LABEL: define void @field_holds_materialized_vo
; %inner's allocation survives (it escaped); %outer's is eliminated.
; CHECK: jeandle.new_instance
; CHECK: call void @sink(i32 %x)
; CHECK-SAME: [ "deopt"(
; CHECK-SAME: i32 99, i32 99,
; descriptor outer (vo_id=0, ScalarValueType, T_OBJECT): (0<<32)|(4<<16)|12 = 262156
; CHECK-SAME: i64 262156, i64 100, i32 2,
; outer field 0 (offset 8, LocalType/T_INT): (8<<32)|10 = 34359738378 -> value %x
; CHECK-SAME: i64 34359738378, i32 %x,
; outer field 1 (offset 16, LocalType/T_OBJECT): (16<<32)|12 = 68719476748
;   -> value is the live (materialized) oop %inner
; CHECK-SAME: i64 68719476748, ptr addrspace(1) %inner,
; %outer's locals slot rewritten to VORef(vo_id=0): (0<<32)|(8<<16)|12 = 524300
; CHECK-SAME: i64 524300, i32 0) ]
; %outer's eliminated OrigAlloc must not appear in the bundle.
; CHECK-NOT: addrspace(1) %outer

!java-method-compilation = !{}
