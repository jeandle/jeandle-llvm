; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Load-through-virtual-ref. VO %outer (klass 100) has a scalar field at offset 8
; (int %x) and a reference field at offset 16 whose stored value is VO %inner
; (klass 200, scalar field at offset 8 = int %y). After the store
; `outer.field16 = inner`, the program LOADS that reference field back into
; %loaded and reads %inner.y through it. The analyzer folds the load:
; %loaded is registered in the alias map as object identity for %inner
; (Aliases.addVirtualAlias at the processLoad VirtualRef branch), and the
; subsequent %ly load folds to %y.
;
; %loaded reaches the deopt bundle as a locals slot. It is object IDENTITY for
; %inner, NOT a byte-offset derived pointer — so %inner must be describable and
; %loaded's bundle slot rewritten to a VORef to %inner. %outer is a direct root
; (its OrigAlloc is a bundle operand) and its offset-16 field is a VORef to
; %inner, so both VOs must be described.
;
; Regression guard (the "identity != address" trap):
; recordDeoptBundleMappings accepts alias-map virtual-alias entries as
; identity. Banning any bundle operand with V != AllocationCall would ban
; %inner; the greatest-fixpoint would then make %outer Bad too (its VORef
; field pointed at a banned VO), and both would materialize.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(i32, i32)
declare i32 @__gxx_personality_v0(...)

define void @load_through_voref(i32 %x, i32 %y) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
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
  ; Load through the reference field: %loaded = outer.field16, which folds to
  ; %inner identity (alias map). Then read %inner.y through it (folds to %y).
  %loaded = load atomic ptr addrspace(1), ptr addrspace(1) %of2 unordered, align 8
  %lf = getelementptr inbounds i8, ptr addrspace(1) %loaded, i64 8
  %ly = load atomic i32, ptr addrspace(1) %lf unordered, align 4
  %ox = load atomic i32, ptr addrspace(1) %of1 unordered, align 4
  ; %outer is a direct root; %loaded is %inner's identity (load-through-ref).
  ; The two locals occupy physical slots 0 and 1.
  call void @sink(i32 %ox, i32 %ly)
       [ "deopt"(i32 99, i32 99, i64 12, ptr addrspace(1) %outer,
                i64 4294967308, ptr addrspace(1) %loaded) ]
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; vo-ids: %outer=0 (allocated first), %inner=1.
; CHECK-LABEL: define void @load_through_voref
; Both OrigAllocs are eliminated (NeverEscapes).
; CHECK-NOT: jeandle.new_instance
; The folded loads feed @sink directly.
; CHECK: call void @sink(i32 %x, i32 %y)
; CHECK-SAME: [ "deopt"(
; CHECK-SAME: i32 99, i32 99,
; Descriptors sit at the VO-section front. The worklist (LIFO from the
; encounter-order roots) plans %inner before %outer, so %inner gets the lower
; SeqNo and its effect applies first; %outer's effect then inserts at the front.
; descriptor outer (vo_id=0, ScalarValueType, T_OBJECT): (0<<32)|(4<<16)|12 = 262156
; CHECK-SAME: i64 262156, i64 100, i32 2,
; outer field 0 (offset 8, LocalType/T_INT): (8<<32)|10 = 34359738378 -> value %x
; CHECK-SAME: i64 34359738378, i32 %x,
; outer field 1 (offset 16, VORefLocalType/T_OBJECT): (16<<32)|(8<<16)|12 = 68720001036
;   -> value is the i32 vo-id of %inner (1)
; CHECK-SAME: i64 68720001036, i32 1,
; descriptor inner (vo_id=1, ScalarValueType, T_OBJECT): (1<<32)|(4<<16)|12 = 4295229452
; CHECK-SAME: i64 4295229452, i64 200, i32 1,
; inner field 0 (offset 8, LocalType/T_INT): (8<<32)|10 = 34359738378 -> value %y
; CHECK-SAME: i64 34359738378, i32 %y,
; %outer's locals slot rewritten to VORef(vo_id=0): the vo-id rides in the
; encoding's index field, so (0<<32)|(8<<16)|12 = 524300, followed by i32 0.
; CHECK-SAME: i64 524300, i32 0,
; %loaded's locals slot rewritten to VORef(vo_id=1) -- the load-through-ref
; identity is accepted, so its slot becomes a VORef to %inner:
; (1<<32)|(8<<16)|12 = 4295491596, followed by i32 1.
; CHECK-SAME: i64 4295491596, i32 1) ]
; The eliminated OrigAllocs (and the folded load) must not appear in the bundle.
; CHECK-NOT: addrspace(1) %outer
; CHECK-NOT: addrspace(1) %inner
; CHECK-NOT: addrspace(1) %loaded

!java-method-compilation = !{}
