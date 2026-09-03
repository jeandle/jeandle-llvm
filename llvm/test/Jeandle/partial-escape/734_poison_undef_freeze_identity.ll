; RUN: opt -passes=verify -disable-output %s
; RUN: opt -S -verify-each -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Poison is a refinement wildcard only while identity is being resolved.
; Undef and arbitrary non-virtual pointers are unknown. Freeze preserves a
; resolved identity, but turns a bare poison/undef into an ordinary unknown
; value. Unknown identity must keep the allocation real instead of enabling
; identity-based folding.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @use(i1)
declare void @use_pointer(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @freeze_poison_not_distinct()
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %normal unwind label %unwind
normal:
  %unknown = freeze ptr addrspace(1) poison
  %same = icmp eq ptr addrspace(1) %o, %unknown
  call void @use(i1 %same)
  ret void
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @freeze_poison_not_distinct(
; CHECK: %[[O:.*]] = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
; CHECK: %[[UNKNOWN:.*]] = freeze ptr addrspace(1) poison
; CHECK: %[[SAME:.*]] = icmp eq ptr addrspace(1) %[[O]], %[[UNKNOWN]]
; CHECK: call void @use(i1 %[[SAME]])

define void @freeze_undef_not_distinct()
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %normal unwind label %unwind
normal:
  %unknown = freeze ptr addrspace(1) undef
  %same = icmp eq ptr addrspace(1) %o, %unknown
  call void @use(i1 %same)
  ret void
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @freeze_undef_not_distinct(
; CHECK: %[[O:.*]] = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
; CHECK: %[[UNKNOWN:.*]] = freeze ptr addrspace(1) undef
; CHECK: %[[SAME:.*]] = icmp eq ptr addrspace(1) %[[O]], %[[UNKNOWN]]
; CHECK: call void @use(i1 %[[SAME]])

define void @external_identity_is_distinct(ptr addrspace(1) nonnull %external)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %normal unwind label %unwind
normal:
  %same = icmp eq ptr addrspace(1) %o, %external
  call void @use(i1 %same)
  ret void
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @external_identity_is_distinct(
; CHECK-NOT: @jeandle.new_instance
; CHECK: call void @use(i1 false)

define void @select_may_contain_same_virtual(
    i1 %cond, ptr addrspace(1) nonnull %external)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %normal unwind label %unwind
normal:
  %maybe.same =
      select i1 %cond, ptr addrspace(1) %o, ptr addrspace(1) %external
  %same = icmp eq ptr addrspace(1) %o, %maybe.same
  call void @use(i1 %same)
  ret void
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @select_may_contain_same_virtual(
; CHECK: %[[O:.*]] = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
; CHECK: %[[MAYBE:.*]] = select i1 %cond, ptr addrspace(1) %[[O]], ptr addrspace(1) %external
; CHECK: %[[SAME:.*]] = icmp eq ptr addrspace(1) %[[O]], %[[MAYBE]]
; CHECK: call void @use(i1 %[[SAME]])

define void @freeze_external_is_not_proven_distinct(
    ptr addrspace(1) %external)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %normal unwind label %unwind
normal:
  %frozen = freeze ptr addrspace(1) %external
  %same = icmp eq ptr addrspace(1) %o, %frozen
  call void @use(i1 %same)
  ret void
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @freeze_external_is_not_proven_distinct(
; CHECK: %[[O:.*]] = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
; CHECK: %[[FROZEN:.*]] = freeze ptr addrspace(1) %external
; CHECK: %[[SAME:.*]] = icmp eq ptr addrspace(1) %[[O]], %[[FROZEN]]
; CHECK: call void @use(i1 %[[SAME]])

define void @zero_gep_external_is_distinct(
    ptr addrspace(1) nonnull %external)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %normal unwind label %unwind
normal:
  %zero = getelementptr i8, ptr addrspace(1) %external, i64 0
  %same = icmp eq ptr addrspace(1) %o, %zero
  call void @use(i1 %same)
  ret void
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @zero_gep_external_is_distinct(
; CHECK-NOT: @jeandle.new_instance
; CHECK: call void @use(i1 false)

define void @nonzero_gep_external_not_proven_distinct(
    ptr addrspace(1) nonnull %external)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %normal unwind label %unwind
normal:
  %derived = getelementptr i8, ptr addrspace(1) %external, i64 8
  %same = icmp eq ptr addrspace(1) %o, %derived
  call void @use(i1 %same)
  ret void
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @nonzero_gep_external_not_proven_distinct(
; CHECK: %[[O:.*]] = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
; CHECK: %[[DERIVED:.*]] = getelementptr i8, ptr addrspace(1) %external, i64 8
; CHECK: %[[SAME:.*]] = icmp eq ptr addrspace(1) %[[O]], %[[DERIVED]]
; CHECK: call void @use(i1 %[[SAME]])

define void @select_undef_is_unknown(i1 %cond)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %normal unwind label %unwind
normal:
  %unknown = select i1 %cond, ptr addrspace(1) %o, ptr addrspace(1) undef
  %same = icmp eq ptr addrspace(1) %o, %unknown
  call void @use(i1 %same)
  ret void
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @select_undef_is_unknown(
; CHECK: %[[O:.*]] = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
; CHECK: %[[UNKNOWN:.*]] = select i1 %cond, ptr addrspace(1) %[[O]], ptr addrspace(1) undef
; CHECK: %[[SAME:.*]] = icmp eq ptr addrspace(1) %[[O]], %[[UNKNOWN]]
; CHECK: call void @use(i1 %[[SAME]])

define void @phi_undef_is_unknown(i1 %cond)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %normal unwind label %unwind
normal:
  br i1 %cond, label %defined, label %unknown.path
defined:
  br label %merge
unknown.path:
  br label %merge
merge:
  %unknown = phi ptr addrspace(1) [ %o, %defined ], [ undef, %unknown.path ]
  %same = icmp eq ptr addrspace(1) %o, %unknown
  call void @use(i1 %same)
  ret void
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @phi_undef_is_unknown(
; CHECK: %[[O:.*]] = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
; CHECK: %[[UNKNOWN:.*]] = phi ptr addrspace(1) [ %[[O]], %defined ], [ undef, %unknown.path ]
; CHECK: %[[SAME:.*]] = icmp eq ptr addrspace(1) %[[O]], %[[UNKNOWN]]
; CHECK: call void @use(i1 %[[SAME]])

define i32 @phi_poison_refines_then_freeze(i1 %cond)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %normal unwind label %unwind
normal:
  %field = getelementptr i8, ptr addrspace(1) %o, i64 8
  store atomic i32 73, ptr addrspace(1) %field unordered, align 4
  br i1 %cond, label %defined, label %wild
defined:
  br label %merge
wild:
  br label %merge
merge:
  %identity = phi ptr addrspace(1) [ %o, %defined ], [ poison, %wild ]
  %frozen = freeze ptr addrspace(1) %identity
  %p = getelementptr i8, ptr addrspace(1) %frozen, i64 8
  %value = load atomic i32, ptr addrspace(1) %p unordered, align 4
  ret i32 %value
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define i32 @phi_poison_refines_then_freeze(
; CHECK-NOT: @jeandle.new_instance
; CHECK-NOT: load atomic
; CHECK-NOT: store atomic
; CHECK: ret i32 73

define void @all_poison_merge_is_unknown(i1 %cond)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %normal unwind label %unwind
normal:
  %all.poison = select i1 %cond, ptr addrspace(1) poison,
                                  ptr addrspace(1) poison
  %unknown = freeze ptr addrspace(1) %all.poison
  %same = icmp eq ptr addrspace(1) %o, %unknown
  call void @use(i1 %same)
  ret void
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @all_poison_merge_is_unknown(
; CHECK: invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
; CHECK: icmp eq ptr addrspace(1)
; CHECK: call void @use(i1 %

define void @freeze_poison_stored_in_virtual_outer()
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %inner = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %outer.alloc unwind label %unwind
outer.alloc:
  %outer = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %normal unwind label %unwind
normal:
  %unknown = freeze ptr addrspace(1) poison
  %field = getelementptr i8, ptr addrspace(1) %outer, i64 8
  store atomic ptr addrspace(1) %unknown, ptr addrspace(1) %field unordered, align 8
  %loaded = load atomic ptr addrspace(1), ptr addrspace(1) %field unordered, align 8
  %same = icmp eq ptr addrspace(1) %inner, %loaded
  call void @use(i1 %same)
  ret void
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @freeze_poison_stored_in_virtual_outer(
; CHECK-COUNT-1: invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
; CHECK: %[[UNKNOWN:.*]] = freeze ptr addrspace(1) poison
; CHECK-NOT: load atomic
; CHECK-NOT: store atomic
; CHECK: %[[SAME:.*]] = icmp eq ptr addrspace(1) %{{.*}}, %[[UNKNOWN]]
; CHECK: call void @use(i1 %[[SAME]])

define void @unknown_select_stored_in_virtual_outer(i1 %cond)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %inner = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %outer.alloc unwind label %unwind
outer.alloc:
  %outer = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %normal unwind label %unwind
normal:
  %unknown = select i1 %cond, ptr addrspace(1) %inner, ptr addrspace(1) undef
  %field = getelementptr i8, ptr addrspace(1) %outer, i64 8
  store atomic ptr addrspace(1) %unknown, ptr addrspace(1) %field unordered, align 8
  %loaded = load atomic ptr addrspace(1), ptr addrspace(1) %field unordered, align 8
  call void @use_pointer(ptr addrspace(1) %loaded)
  ret void
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @unknown_select_stored_in_virtual_outer(
; CHECK: %inner = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
; CHECK: %[[UNKNOWN:.*]] = select i1 %cond, ptr addrspace(1) %inner, ptr addrspace(1) undef
; CHECK-NOT: %outer = invoke
; CHECK-NOT: store atomic
; CHECK-NOT: load atomic
; CHECK: call void @use_pointer(ptr addrspace(1) %[[UNKNOWN]])
; CHECK-NOT: poison

define i32 @zero_offset_poison_refines(i1 %cond)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %normal unwind label %unwind
normal:
  %field = getelementptr i8, ptr addrspace(1) %o, i64 8
  store atomic i32 91, ptr addrspace(1) %field unordered, align 4
  %zero = getelementptr i8, ptr addrspace(1) %o, i64 0
  %identity = select i1 %cond, ptr addrspace(1) %zero,
                                ptr addrspace(1) poison
  %selected.field = getelementptr i8, ptr addrspace(1) %identity, i64 8
  %value = load atomic i32, ptr addrspace(1) %selected.field unordered, align 4
  ret i32 %value
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define i32 @zero_offset_poison_refines(
; CHECK-NOT: @jeandle.new_instance
; CHECK-NOT: load atomic
; CHECK-NOT: store atomic
; CHECK: ret i32 91

define void @nonzero_offset_poison_is_unknown(i1 %cond)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 32, i1 false)
       to label %normal unwind label %unwind
normal:
  %derived = getelementptr i8, ptr addrspace(1) %o, i64 8
  %unknown = select i1 %cond, ptr addrspace(1) %derived,
                               ptr addrspace(1) poison
  %same = icmp eq ptr addrspace(1) %o, %unknown
  call void @use(i1 %same)
  ret void
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @nonzero_offset_poison_is_unknown(
; CHECK: invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
; CHECK: getelementptr i8, ptr addrspace(1) %{{.*}}, i64 8
; CHECK: select i1 %cond
; CHECK: icmp eq ptr addrspace(1)

define void @symbolic_offset_poison_is_unknown(i1 %cond, i64 %offset)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 32, i1 false)
       to label %normal unwind label %unwind
normal:
  %derived = getelementptr i8, ptr addrspace(1) %o, i64 %offset
  %unknown = select i1 %cond, ptr addrspace(1) %derived,
                               ptr addrspace(1) poison
  %same = icmp eq ptr addrspace(1) %o, %unknown
  call void @use(i1 %same)
  ret void
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @symbolic_offset_poison_is_unknown(
; CHECK: invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
; CHECK: getelementptr i8, ptr addrspace(1) %{{.*}}, i64 %offset
; CHECK: select i1 %cond
; CHECK: icmp eq ptr addrspace(1)

define void @poison_condition_equal_arms(i1 %ignored)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %normal unwind label %unwind
normal:
  %identity = select i1 poison, ptr addrspace(1) %o, ptr addrspace(1) %o
  %frozen = freeze ptr addrspace(1) %identity
  %same = icmp eq ptr addrspace(1) %frozen, %o
  call void @use(i1 %same)
  ret void
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @poison_condition_equal_arms(
; CHECK-NOT: @jeandle.new_instance
; CHECK: call void @use(i1 true)

define void @poison_condition_different_arms()
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %second unwind label %unwind
second:
  %b = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %normal unwind label %unwind
normal:
  %unknown = select i1 poison, ptr addrspace(1) %a, ptr addrspace(1) %b
  %frozen = freeze ptr addrspace(1) %unknown
  %same = icmp eq ptr addrspace(1) %frozen, %a
  call void @use(i1 %same)
  ret void
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @poison_condition_different_arms(
; CHECK-COUNT-2: invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
; CHECK: select i1 poison
; CHECK: icmp eq ptr addrspace(1)
; CHECK: call void @use(i1 %

define void @different_virtual_bases_are_distinct()
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %second unwind label %unwind
second:
  %b = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %normal unwind label %unwind
normal:
  %same = icmp eq ptr addrspace(1) %a, %b
  call void @use(i1 %same)
  ret void
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @different_virtual_bases_are_distinct(
; CHECK-NOT: @jeandle.new_instance
; CHECK: call void @use(i1 false)

define void @different_virtual_derived_not_proven_distinct()
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %second unwind label %unwind
second:
  %b = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %normal unwind label %unwind
normal:
  %one.past = getelementptr i8, ptr addrspace(1) %a, i64 16
  %same = icmp eq ptr addrspace(1) %one.past, %b
  call void @use(i1 %same)
  ret void
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @different_virtual_derived_not_proven_distinct(
; CHECK-COUNT-2: invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
; CHECK: %[[DERIVED:.*]] = getelementptr i8, ptr addrspace(1) %a, i64 16
; CHECK: %[[SAME:.*]] = icmp eq ptr addrspace(1) %[[DERIVED]], %b
; CHECK: call void @use(i1 %[[SAME]])

define void @different_virtual_symbolic_not_proven_distinct(i64 %offset)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %second unwind label %unwind
second:
  %b = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %normal unwind label %unwind
normal:
  %derived = getelementptr i8, ptr addrspace(1) %a, i64 %offset
  %same = icmp eq ptr addrspace(1) %derived, %b
  call void @use(i1 %same)
  ret void
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @different_virtual_symbolic_not_proven_distinct(
; CHECK-COUNT-2: invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
; CHECK: %[[DERIVED:.*]] = getelementptr i8, ptr addrspace(1) %a, i64 %offset
; CHECK: %[[SAME:.*]] = icmp eq ptr addrspace(1) %[[DERIVED]], %b
; CHECK: call void @use(i1 %[[SAME]])

!java-method-compilation = !{}
