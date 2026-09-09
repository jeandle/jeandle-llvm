; RUN: opt -S -verify-each \
; RUN:   -passes="require<partial-escape-analysis>,partial-escape-transform" \
; RUN:   %s -o %t
; RUN: FileCheck %s --check-prefixes=META,SPLIT,TYPED,TAIL,ATTR,MULTIUSER,SEPARATED,GEPMETA,WRONGCC,BUNDLE,CALLMETA,OVERLONG,INTRA-GROUP < %t
; RUN: not grep '!jeandle[.]pea[.]replay' %t
; RUN: opt -disable-output -verify-each \
; RUN:   -passes="require<partial-escape-analysis>,partial-escape-transform" \
; RUN:   -jeandle-trace-pea %s 2>&1 \
; RUN:   | FileCheck %s --check-prefix=TRACE-BUNDLE

; A replay suffix is reusable only when it has the exact form emitted by the
; transform. Semantically similar source instructions are deliberately placed
; immediately before the escape so a permissive matcher would retain them.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare hotspotcc void @jeandle.monitorenter_with_lightweight_lock(ptr addrspace(1), ptr) nounwind
declare hotspotcc void @jeandle.monitorexit_with_lightweight_lock(ptr addrspace(1), ptr) nounwind
declare void @sink(ptr addrspace(1))
declare void @semantic_marker()
declare void @llvm.assume(i1 noundef)
declare i32 @__gxx_personality_v0(...)

define void @store_metadata_is_not_replay(i1 %escape, i32 %value)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
           ptr inttoptr (i64 68301 to ptr), i32 16, i1 false)
       to label %body unwind label %unwind
body:
  br i1 %escape, label %escape.block, label %done
escape.block:
  %slot = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  store atomic i32 %value, ptr addrspace(1) %slot unordered, align 4,
      !nontemporal !0
  call void @sink(ptr addrspace(1) %o)
  br label %done
done:
  ret void
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; META-LABEL: define void @store_metadata_is_not_replay(
; META: escape.block:
; META-NEXT: %[[META_SLOT:[A-Za-z0-9._]+]] = getelementptr inbounds{{( nuw)?}} i8, ptr addrspace(1) %{{[A-Za-z0-9._]+}}, i64 8
; META-NEXT: store atomic i32 %value, ptr addrspace(1) %[[META_SLOT]] unordered, align 4
; META-NOT: !nontemporal
; META-NEXT: call void @sink

define void @split_gep_is_not_replay(i1 %escape, i32 %value)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
           ptr inttoptr (i64 68302 to ptr), i32 16, i1 false)
       to label %body unwind label %unwind
body:
  br i1 %escape, label %escape.block, label %done
escape.block:
  %slot.first = getelementptr inbounds i8, ptr addrspace(1) %o, i64 4
  %slot = getelementptr inbounds i8, ptr addrspace(1) %slot.first, i64 4
  store atomic i32 %value, ptr addrspace(1) %slot unordered, align 4
  call void @sink(ptr addrspace(1) %o)
  br label %done
done:
  ret void
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; SPLIT-LABEL: define void @split_gep_is_not_replay(
; SPLIT: escape.block:
; SPLIT-NOT: getelementptr{{.*}}i64 4
; SPLIT-NEXT: %[[SPLIT_SLOT:[A-Za-z0-9._]+]] = getelementptr inbounds{{( nuw)?}} i8, ptr addrspace(1) %{{[A-Za-z0-9._]+}}, i64 8
; SPLIT-NEXT: store atomic i32 %value, ptr addrspace(1) %[[SPLIT_SLOT]] unordered, align 4
; SPLIT-NEXT: call void @sink

define void @typed_gep_is_not_replay(i1 %escape, i64 %value)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
           ptr inttoptr (i64 68303 to ptr), i32 16, i1 false)
       to label %body unwind label %unwind
body:
  br i1 %escape, label %escape.block, label %done
escape.block:
  %slot = getelementptr inbounds i64, ptr addrspace(1) %o, i64 1
  store atomic i64 %value, ptr addrspace(1) %slot unordered, align 8
  call void @sink(ptr addrspace(1) %o)
  br label %done
done:
  ret void
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; TYPED-LABEL: define void @typed_gep_is_not_replay(
; TYPED: escape.block:
; TYPED-NOT: getelementptr{{.*}} i64,
; TYPED-NEXT: %[[TYPED_SLOT:[A-Za-z0-9._]+]] = getelementptr inbounds{{( nuw)?}} i8, ptr addrspace(1) %{{[A-Za-z0-9._]+}}, i64 8
; TYPED-NEXT: store atomic i64 %value, ptr addrspace(1) %[[TYPED_SLOT]] unordered, align 8
; TYPED-NEXT: call void @sink

define void @tail_monitorenter_is_not_replay(i1 %escape)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %lock = alloca i64, align 8
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
           ptr inttoptr (i64 68304 to ptr), i32 16, i1 false)
       to label %body unwind label %unwind
body:
  br i1 %escape, label %escape.block, label %done
escape.block:
  tail call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
      ptr addrspace(1) %o, ptr %lock)
  call void @sink(ptr addrspace(1) %o)
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
      ptr addrspace(1) %o, ptr %lock)
  br label %done
done:
  ret void
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; TAIL-LABEL: define void @tail_monitorenter_is_not_replay(
; TAIL: escape.block:
; TAIL-NEXT: {{^  call hotspotcc void @jeandle\.monitorenter_with_lightweight_lock\(.*\)$}}
; TAIL-NEXT: call void @sink

define void @attributed_monitorenter_is_replay(i1 %escape)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %lock = alloca i64, align 8
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
           ptr inttoptr (i64 68305 to ptr), i32 16, i1 false)
       to label %body unwind label %unwind
body:
  br i1 %escape, label %escape.block, label %done
escape.block:
  call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
      ptr addrspace(1) %o, ptr %lock) #0
  call void @sink(ptr addrspace(1) %o)
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
      ptr addrspace(1) %o, ptr %lock)
  br label %done
done:
  ret void
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; ATTR-LABEL: define void @attributed_monitorenter_is_replay(
; ATTR: escape.block:
; The matcher ignores call-site attributes (PEA's emitter adds none), so the
; attributed monitorenter is reused verbatim as the replay, #0 preserved.
; ATTR-NEXT: {{^  call hotspotcc void @jeandle\.monitorenter_with_lightweight_lock\(.*\) #0$}}
; ATTR-NEXT: call void @sink
; ATTR-NOT: call hotspotcc void @jeandle.monitorenter_with_lightweight_lock

; The store is still immediately preceded by its GEP. The assume after the
; escape is a known nonescaping intrinsic use of the same pointer, so only the
; GEP's multi-user property can reject this suffix.
define void @multi_user_gep_is_not_replay(i1 %escape, i32 %value)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
           ptr inttoptr (i64 68306 to ptr), i32 16, i1 false)
       to label %body unwind label %unwind
body:
  br i1 %escape, label %escape.block, label %done
escape.block:
  %slot = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  store atomic i32 %value, ptr addrspace(1) %slot unordered, align 4
  call void @sink(ptr addrspace(1) %o)
  call void @llvm.assume(i1 true)
      [ "nonnull"(ptr addrspace(1) %slot) ]
  br label %done
done:
  ret void
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; MULTIUSER-LABEL: define void @multi_user_gep_is_not_replay(
; MULTIUSER: escape.block:
; MULTIUSER-NEXT: %slot = getelementptr inbounds{{( nuw)?}} i8,
; MULTIUSER-NEXT: %pea.matslot = getelementptr inbounds{{( nuw)?}} i8,
; MULTIUSER-NEXT: store atomic i32 %value, ptr addrspace(1) %pea.matslot unordered, align 4
; MULTIUSER-NEXT: call void @sink
; MULTIUSER-NEXT: call void @llvm.assume(i1 true) [ "nonnull"(ptr addrspace(1) %slot) ]

; An unrelated semantic operation between the GEP and store prevents the pair
; from being the contiguous sequence emitted by materialization.
define void @separated_gep_is_not_replay(i1 %escape, i32 %value)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
           ptr inttoptr (i64 68307 to ptr), i32 16, i1 false)
       to label %body unwind label %unwind
body:
  br i1 %escape, label %escape.block, label %done
escape.block:
  %slot = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  call void @semantic_marker()
  store atomic i32 %value, ptr addrspace(1) %slot unordered, align 4
  call void @sink(ptr addrspace(1) %o)
  br label %done
done:
  ret void
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; SEPARATED-LABEL: define void @separated_gep_is_not_replay(
; SEPARATED: escape.block:
; SEPARATED-NEXT: call void @semantic_marker()
; SEPARATED-NEXT: %pea.matslot = getelementptr inbounds{{( nuw)?}} i8,
; SEPARATED-NEXT: store atomic i32 %value, ptr addrspace(1) %pea.matslot unordered, align 4
; SEPARATED-NEXT: call void @sink

define void @gep_metadata_is_not_replay(i1 %escape, i32 %value)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
           ptr inttoptr (i64 68308 to ptr), i32 16, i1 false)
       to label %body unwind label %unwind
body:
  br i1 %escape, label %escape.block, label %done
escape.block:
  %slot = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8,
      !annotation !1
  store atomic i32 %value, ptr addrspace(1) %slot unordered, align 4
  call void @sink(ptr addrspace(1) %o)
  br label %done
done:
  ret void
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; GEPMETA-LABEL: define void @gep_metadata_is_not_replay(
; GEPMETA: escape.block:
; GEPMETA-NEXT: %pea.matslot = getelementptr inbounds{{( nuw)?}} i8,
; GEPMETA-NOT: !annotation
; GEPMETA-NEXT: store atomic i32 %value, ptr addrspace(1) %pea.matslot unordered, align 4
; GEPMETA-NEXT: call void @sink

define void @wrong_cc_monitorenter_is_not_replay(i1 %escape)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %lock = alloca i64, align 8
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
           ptr inttoptr (i64 68309 to ptr), i32 16, i1 false)
       to label %body unwind label %unwind
body:
  br i1 %escape, label %escape.block, label %done
escape.block:
  call void @jeandle.monitorenter_with_lightweight_lock(
      ptr addrspace(1) %o, ptr %lock)
  call void @sink(ptr addrspace(1) %o)
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
      ptr addrspace(1) %o, ptr %lock)
  br label %done
done:
  ret void
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; WRONGCC-LABEL: define void @wrong_cc_monitorenter_is_not_replay(
; WRONGCC: escape.block:
; WRONGCC-NEXT: call hotspotcc void @jeandle.monitorenter_with_lightweight_lock
; WRONGCC-NEXT: call void @sink

; A source monitorenter with an operand bundle is not the canonical replay
; shape emitted by PEA. The analyzer may still optimize the monitor normally;
; the transform must replace it with one canonical bundle-free replay rather
; than mistake the source call for replay it already emitted.
define void @bundled_monitorenter_is_not_replay(i1 %escape)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %lock = alloca i64, align 8
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
           ptr inttoptr (i64 68310 to ptr), i32 16, i1 false)
       to label %body unwind label %unwind
body:
  br i1 %escape, label %escape.block, label %done
escape.block:
  call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
      ptr addrspace(1) %o, ptr %lock) [ "replay.test"(i32 7) ]
  call void @sink(ptr addrspace(1) %o)
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
      ptr addrspace(1) %o, ptr %lock)
  br label %done
done:
  ret void
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; BUNDLE-LABEL: define void @bundled_monitorenter_is_not_replay(
; BUNDLE: %[[BUNDLE_O:[A-Za-z0-9._]+]] = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 68310 to ptr), i32 16, i1 false)
; BUNDLE: escape.block:
; BUNDLE-NEXT: call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(ptr addrspace(1) %[[BUNDLE_O]], ptr %lock)
; BUNDLE-NEXT: call void @sink(ptr addrspace(1) %[[BUNDLE_O]])
; BUNDLE-NEXT: call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(ptr addrspace(1) %[[BUNDLE_O]], ptr %lock)
; BUNDLE-NOT: @jeandle.monitorenter_with_lightweight_lock
; BUNDLE: }

; TRACE-BUNDLE: PEA: ReplaceCall function=@bundled_monitorenter_is_not_replay

define void @metadata_monitorenter_is_replay(i1 %escape)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %lock = alloca i64, align 8
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
           ptr inttoptr (i64 68311 to ptr), i32 16, i1 false)
       to label %body unwind label %unwind
body:
  br i1 %escape, label %escape.block, label %done
escape.block:
  call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
      ptr addrspace(1) %o, ptr %lock), !annotation !1
  call void @sink(ptr addrspace(1) %o)
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
      ptr addrspace(1) %o, ptr %lock)
  br label %done
done:
  ret void
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CALLMETA-LABEL: define void @metadata_monitorenter_is_replay(
; CALLMETA: escape.block:
; The matcher ignores call metadata (PEA's emitter adds none), so the annotated
; monitorenter is reused verbatim as the replay, !annotation preserved.
; CALLMETA-NEXT: {{^  call hotspotcc void @jeandle\.monitorenter_with_lightweight_lock\(.*\), !annotation ![0-9]+$}}
; CALLMETA-NEXT: call void @sink
; CALLMETA-NOT: call hotspotcc void @jeandle.monitorenter_with_lightweight_lock

; Only the second store is in the materialized field state. The preceding
; store makes the apparent one-store suffix overlong, so the tail must be
; replaced rather than retained as a replay boundary.
define void @overlong_store_suffix_is_not_replay(i1 %escape, i32 %old,
                                                  i32 %value)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
           ptr inttoptr (i64 68312 to ptr), i32 16, i1 false)
       to label %body unwind label %unwind
body:
  br i1 %escape, label %escape.block, label %done
escape.block:
  %old.slot = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  store atomic i32 %old, ptr addrspace(1) %old.slot unordered, align 4
  %tail.slot = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  store atomic i32 %value, ptr addrspace(1) %tail.slot unordered, align 4
  call void @sink(ptr addrspace(1) %o)
  br label %done
done:
  ret void
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; OVERLONG-LABEL: define void @overlong_store_suffix_is_not_replay(
; OVERLONG: escape.block:
; OVERLONG-NOT: tail.slot
; OVERLONG-NEXT: %pea.matslot = getelementptr inbounds{{( nuw)?}} i8,
; OVERLONG-NEXT: store atomic i32 %value, ptr addrspace(1) %pea.matslot unordered, align 4
; OVERLONG-NEXT: call void @sink

; Complete field groups for distinct real allocations may commute before
; publication, but fields within one allocation's group remain ordered.  The
; apparent suffix below has B's complete group followed by A's fields in the
; reverse of A's tracked field order.  It must be rebuilt rather than accepted
; as a permutation of individual stores.
define void @intra_object_field_order_is_not_permutable(
    i1 %escape, i32 %a0, i32 %a1, i32 %b0)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
           ptr inttoptr (i64 68314 to ptr), i32 24, i1 false)
       to label %alloc.b unwind label %unwind
alloc.b:
  %b = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
           ptr inttoptr (i64 68315 to ptr), i32 16, i1 false)
       to label %body unwind label %unwind
body:
  %a.slot0 = getelementptr inbounds i8, ptr addrspace(1) %a, i64 8
  store atomic i32 %a0, ptr addrspace(1) %a.slot0 unordered, align 4
  %a.slot1 = getelementptr inbounds i8, ptr addrspace(1) %a, i64 12
  store atomic i32 %a1, ptr addrspace(1) %a.slot1 unordered, align 4
  %a.ref = getelementptr inbounds i8, ptr addrspace(1) %a, i64 16
  store atomic ptr addrspace(1) %b, ptr addrspace(1) %a.ref unordered, align 8
  %b.slot0 = getelementptr inbounds i8, ptr addrspace(1) %b, i64 8
  store atomic i32 %b0, ptr addrspace(1) %b.slot0 unordered, align 4
  br i1 %escape, label %escape.block, label %done
escape.block:
  %suffix.b.slot0 = getelementptr inbounds i8, ptr addrspace(1) %b, i64 8
  store atomic i32 %b0, ptr addrspace(1) %suffix.b.slot0 unordered, align 4
  %suffix.a.ref = getelementptr inbounds i8, ptr addrspace(1) %a, i64 16
  store atomic ptr addrspace(1) %b, ptr addrspace(1) %suffix.a.ref unordered,
      align 8
  %suffix.a.slot1 = getelementptr inbounds i8, ptr addrspace(1) %a, i64 12
  store atomic i32 %a1, ptr addrspace(1) %suffix.a.slot1 unordered, align 4
  %suffix.a.slot0 = getelementptr inbounds i8, ptr addrspace(1) %a, i64 8
  store atomic i32 %a0, ptr addrspace(1) %suffix.a.slot0 unordered, align 4
  call void @sink(ptr addrspace(1) %a)
  br label %done
done:
  ret void
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; INTRA-GROUP-LABEL: define void @intra_object_field_order_is_not_permutable(
; INTRA-GROUP: %[[A:[A-Za-z0-9._]+]] = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; INTRA-GROUP: %[[B:[A-Za-z0-9._]+]] = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; INTRA-GROUP: escape.block:
; INTRA-GROUP-NEXT: %[[B_SLOT:[A-Za-z0-9._]+]] = getelementptr inbounds{{( nuw)?}} i8, ptr addrspace(1) %[[B]], i64 8
; INTRA-GROUP-NEXT: store atomic i32 %b0, ptr addrspace(1) %[[B_SLOT]] unordered, align 4
; INTRA-GROUP-NEXT: %[[A_SLOT0:[A-Za-z0-9._]+]] = getelementptr inbounds{{( nuw)?}} i8, ptr addrspace(1) %[[A]], i64 8
; INTRA-GROUP-NEXT: store atomic i32 %a0, ptr addrspace(1) %[[A_SLOT0]] unordered, align 4
; INTRA-GROUP-NEXT: %[[A_SLOT1:[A-Za-z0-9._]+]] = getelementptr inbounds{{( nuw)?}} i8, ptr addrspace(1) %[[A]], i64 12
; INTRA-GROUP-NEXT: store atomic i32 %a1, ptr addrspace(1) %[[A_SLOT1]] unordered, align 4
; INTRA-GROUP-NEXT: %[[A_REF:[A-Za-z0-9._]+]] = getelementptr inbounds{{( nuw)?}} i8, ptr addrspace(1) %[[A]], i64 16
; INTRA-GROUP-NEXT: store atomic ptr addrspace(1) %[[B]], ptr addrspace(1) %[[A_REF]] unordered, align 8
; INTRA-GROUP-NEXT: call void @sink(ptr addrspace(1) %[[A]])

attributes #0 = { nounwind }

!0 = !{i32 1}
!1 = !{!"replay-shape"}

!java-method-compilation = !{}
