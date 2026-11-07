; RUN: opt -S -verify-each \
; RUN:   -passes="require<partial-escape-analysis>,partial-escape-transform" \
; RUN:   -jeandle-vm-callback-log=%S/Inputs/801_copy_fold_drop_dead_reaching_def.cblog \
; RUN:   %s | FileCheck %s

; A concrete-source copy fold overwrites a previously folded destination
; store, and the destination later turns ineligible (the value-based-class
; check on its klass must observe a real oop). The pre-copy store is DEAD
; under the revived copy — the restored call rewrites the whole window — so
; the fold must clear the store's reaching-def entry when it takes over the
; slot. Otherwise markIneligible observes the stale definition and commit
; restores the store as a keep-real survivor, leaving a redundant store that
; the revived copy immediately overwrites. With the reaching-def entry
; cleared, the store's EliminateStore effect survives the drop as an
; unobserved dead store and the transform deletes it.

declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32)
declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare hotspotcc i1 @jeandle.check_if_value_based(ptr addrspace(1))
declare void @sink_i1(i1)
declare void @sink(ptr addrspace(1))
declare void @jeandle.copy(ptr addrspace(1), i64, ptr addrspace(1), i64, i64, ptr, ptr, i64, i64)
declare i32 @__gxx_personality_v0(...)

@instanceOopDesc.base_offset_in_bytes = constant i64 16

define i32 @copy_fold_drop_dead_reaching_def(
    ptr addrspace(1) "java-klass"="12345" %src)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %dest = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
            ptr inttoptr (i64 12345 to ptr), i32 2, i32 24, i32 16, i32 1048576)
         to label %do_store unwind label %u
do_store:
  %dx0 = getelementptr inbounds i8, ptr addrspace(1) %dest, i64 16
  store atomic i32 99, ptr addrspace(1) %dx0 unordered, align 4
  br label %do_copy
do_copy:
  call void @jeandle.copy(ptr addrspace(1) %src, i64 0, ptr addrspace(1) %dest, i64 0, i64 2,
                          ptr null, ptr null, i64 2, i64 2)
      #0 [ "deopt"(i32 99, i32 99, i64 12, ptr addrspace(1) null) ]
  br label %value_based
value_based:
  ; The destination's klass is value-based: the runtime warning must observe
  ; a real oop, so the destination drops to ineligible and the copy fold is
  ; revived.
  %vb = call hotspotcc i1 @jeandle.check_if_value_based(ptr addrspace(1) %dest)
  call void @sink_i1(i1 %vb)
  br label %read
read:
  ; Real loads after the drop: they read the revived copy's writes.
  %dx = getelementptr inbounds i8, ptr addrspace(1) %dest, i64 16
  %vx = load atomic i32, ptr addrspace(1) %dx unordered, align 4
  %dy = getelementptr inbounds i8, ptr addrspace(1) %dest, i64 20
  %vy = load atomic i32, ptr addrspace(1) %dy unordered, align 4
  %sum = add i32 %vx, %vy
  ret i32 %sum
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; The virtual-to-virtual instance-clone variant of the same drop: the value
; based check on the CLONE destination invalidates the fold, the surviving
; use audit retires the source allocation, and the retried attempt re-folds
; the copy through the concrete-source path. The stale pre-clone store must
; stay dead in the retry as well: the re-fold clears its reaching-def entry
; again, so no attempt ever revives it.
define i32 @v2v_drop_dead_reaching_def() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %other = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 30002 to ptr), i32 16, i1 false)
         to label %init unwind label %u
init:
  %src = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 30001 to ptr), i32 32, i1 false)
         to label %stores unwind label %u
stores:
  %sx = getelementptr inbounds i8, ptr addrspace(1) %src, i64 16
  %sy = getelementptr inbounds i8, ptr addrspace(1) %src, i64 20
  %sr = getelementptr inbounds i8, ptr addrspace(1) %src, i64 24
  store atomic i32 7, ptr addrspace(1) %sx unordered, align 4
  store atomic i32 9, ptr addrspace(1) %sy unordered, align 4
  store atomic ptr addrspace(1) %other, ptr addrspace(1) %sr unordered, align 8
  %dst = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 30001 to ptr), i32 32, i1 false)
         to label %stale unwind label %u
stale:
  %dx0 = getelementptr inbounds i8, ptr addrspace(1) %dst, i64 16
  store atomic i32 99, ptr addrspace(1) %dx0 unordered, align 4
  br label %do_clone
do_clone:
  call void @jeandle.copy(ptr addrspace(1) %src, i64 16, ptr addrspace(1) %dst, i64 16,
                          i64 2, ptr null, ptr null, i64 32, i64 32)
      #1 [ "deopt"(i32 99, i32 99, i64 12, ptr addrspace(1) null) ]
  br label %value_based
value_based:
  %vb = call hotspotcc i1 @jeandle.check_if_value_based(ptr addrspace(1) %dst)
  call void @sink_i1(i1 %vb)
  br label %read
read:
  %dx = getelementptr inbounds i8, ptr addrspace(1) %dst, i64 16
  %dy = getelementptr inbounds i8, ptr addrspace(1) %dst, i64 20
  %vx = load atomic i32, ptr addrspace(1) %dx unordered, align 4
  %vy = load atomic i32, ptr addrspace(1) %dy unordered, align 4
  %sum = add i32 %vx, %vy
  ret i32 %sum
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}


; The destination went ineligible: the allocation and the copy call stay
; real, and the value-based check operates on the real object.
; CHECK-LABEL: define i32 @copy_fold_drop_dead_reaching_def
; CHECK: %dest = invoke hotspotcc ptr addrspace(1) @jeandle.new_array
; The pre-copy store is dead under the revived copy and must not come back:
; the fold cleared its reaching-def entry, so the drop path leaves it
; eliminated instead of restoring a keep-real survivor.
; CHECK-NOT: store atomic
; CHECK: call void @jeandle.copy
; CHECK: call hotspotcc i1 @jeandle.check_if_value_based(ptr addrspace(1) %dest)
; The post-drop reads are real loads of the revived copy's output.
; CHECK: load atomic i32, ptr addrspace(1)
; CHECK: load atomic i32, ptr addrspace(1)
; CHECK: ret i32

; The retry keeps every allocation and the source's stores real (the revived
; copy reads them) and the stale pre-clone store dead.
; CHECK-LABEL: define i32 @v2v_drop_dead_reaching_def
; CHECK: %other = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK: %src = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK: store atomic i32 7, ptr addrspace(1)
; CHECK: store atomic i32 9, ptr addrspace(1)
; CHECK: store atomic ptr addrspace(1) %other, ptr addrspace(1)
; CHECK: %dst = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK-NOT: store atomic i32 99
; CHECK: call void @jeandle.copy
; CHECK: call hotspotcc i1 @jeandle.check_if_value_based(ptr addrspace(1) %dst)
; CHECK: ret i32

; A same-array overlapping copy whose array later turns ineligible: the
; revived call READS the pre-copy values of the source window, so the
; intersection's stores must come back (only the destination-only slot's
; store stays dead).
define i32 @selfoverlap_drop_reaching_defs() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
            ptr inttoptr (i64 12345 to ptr), i32 4, i32 32, i32 16, i32 1048576)
         to label %stores unwind label %u
stores:
  %p1 = getelementptr inbounds i8, ptr addrspace(1) %a, i64 16
  %p2 = getelementptr inbounds i8, ptr addrspace(1) %a, i64 20
  %p3 = getelementptr inbounds i8, ptr addrspace(1) %a, i64 24
  %p4 = getelementptr inbounds i8, ptr addrspace(1) %a, i64 28
  store atomic i32 1, ptr addrspace(1) %p1 unordered, align 4
  store atomic i32 2, ptr addrspace(1) %p2 unordered, align 4
  store atomic i32 3, ptr addrspace(1) %p3 unordered, align 4
  store atomic i32 4, ptr addrspace(1) %p4 unordered, align 4
  br label %do_copy
do_copy:
  ; System.arraycopy(a, 1, a, 0, 3): dest window [16,28), source window
  ; [20,32) — the intersection [20,28) is both read and rewritten.
  invoke void @jeandle.copy(ptr addrspace(1) %a, i64 1, ptr addrspace(1) %a, i64 0, i64 3,
                            ptr null, ptr null, i64 4, i64 4)
      #0 [ "deopt"(i32 99, i32 99, i64 12, ptr addrspace(1) null) ]
      to label %value_based unwind label %u
value_based:
  %vb = call hotspotcc i1 @jeandle.check_if_value_based(ptr addrspace(1) %a)
  call void @sink_i1(i1 %vb)
  br label %read
read:
  ; After the drop these are real loads of the revived copy's output:
  ; [2, 3, 4, 4].
  %q0 = getelementptr inbounds i8, ptr addrspace(1) %a, i64 16
  %q2 = getelementptr inbounds i8, ptr addrspace(1) %a, i64 24
  %v0 = load atomic i32, ptr addrspace(1) %q0 unordered, align 4
  %v2 = load atomic i32, ptr addrspace(1) %q2 unordered, align 4
  %sum = add i32 %v0, %v2
  ret i32 %sum
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; A virtual source that escapes only AFTER the dropped copy: the revived
; call reads the source's memory before the source's later materialization
; replays it, so the fold must keep the source's stores restorable at their
; original positions.
define i32 @v2v_late_src_escape_drop() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %src = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
            ptr inttoptr (i64 12345 to ptr), i32 2, i32 24, i32 16, i32 1048576)
         to label %stores unwind label %u
stores:
  %sx = getelementptr inbounds i8, ptr addrspace(1) %src, i64 16
  store atomic i32 7, ptr addrspace(1) %sx unordered, align 4
  %dst = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
            ptr inttoptr (i64 12345 to ptr), i32 2, i32 24, i32 16, i32 1048576)
         to label %do_copy unwind label %u
do_copy:
  invoke void @jeandle.copy(ptr addrspace(1) %src, i64 0, ptr addrspace(1) %dst, i64 0, i64 2,
                            ptr null, ptr null, i64 2, i64 2)
      #0 [ "deopt"(i32 99, i32 99, i64 12, ptr addrspace(1) null) ]
      to label %value_based unwind label %u
value_based:
  ; The destination turns ineligible: the copy call revives and reads %src.
  %vb = call hotspotcc i1 @jeandle.check_if_value_based(ptr addrspace(1) %dst)
  call void @sink_i1(i1 %vb)
  br label %late_escape
late_escape:
  ; The source escapes only here — its materialization replay happens after
  ; the revived call.
  call void @sink(ptr addrspace(1) %src)
  br label %read
read:
  %dx = getelementptr inbounds i8, ptr addrspace(1) %dst, i64 16
  %vx = load atomic i32, ptr addrspace(1) %dx unordered, align 4
  ret i32 %vx
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; A post-copy store to a SOURCE slot kills the pre-copy store's entry in the
; point-sensitive reaching-def map. The fold observes the read side AT the
; fold (before the kill), so when the drop keeps the source real BOTH
; stores come back at their original positions and the revived call reads
; the pre-copy value.
define i32 @v2v_postcopy_store_drop() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %src = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
            ptr inttoptr (i64 12345 to ptr), i32 2, i32 24, i32 16, i32 1048576)
         to label %stores unwind label %u
stores:
  %sx = getelementptr inbounds i8, ptr addrspace(1) %src, i64 16
  store atomic i32 7, ptr addrspace(1) %sx unordered, align 4
  %dst = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
            ptr inttoptr (i64 12345 to ptr), i32 2, i32 24, i32 16, i32 1048576)
         to label %do_copy unwind label %u
do_copy:
  invoke void @jeandle.copy(ptr addrspace(1) %src, i64 0, ptr addrspace(1) %dst, i64 0, i64 2,
                            ptr null, ptr null, i64 2, i64 2)
      #0 [ "deopt"(i32 99, i32 99, i64 12, ptr addrspace(1) null) ]
      to label %post_store unwind label %u
post_store:
  %sx2 = getelementptr inbounds i8, ptr addrspace(1) %src, i64 16
  store atomic i32 42, ptr addrspace(1) %sx2 unordered, align 4
  br label %value_based
value_based:
  %vb = call hotspotcc i1 @jeandle.check_if_value_based(ptr addrspace(1) %dst)
  call void @sink_i1(i1 %vb)
  br label %read
read:
  %dx = getelementptr inbounds i8, ptr addrspace(1) %dst, i64 16
  %vx = load atomic i32, ptr addrspace(1) %dx unordered, align 4
  ret i32 %vx
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; The same kill for a same-array overlapping copy: a post-copy store to an
; intersection slot kills the kept entry. The fold observed the source
; window before the kill, so the intersection store survives alongside the
; killing store.
define i32 @selfoverlap_postcopy_store_drop() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
            ptr inttoptr (i64 12345 to ptr), i32 4, i32 32, i32 16, i32 1048576)
         to label %stores unwind label %u
stores:
  %p1 = getelementptr inbounds i8, ptr addrspace(1) %a, i64 16
  %p2 = getelementptr inbounds i8, ptr addrspace(1) %a, i64 20
  %p3 = getelementptr inbounds i8, ptr addrspace(1) %a, i64 24
  %p4 = getelementptr inbounds i8, ptr addrspace(1) %a, i64 28
  store atomic i32 1, ptr addrspace(1) %p1 unordered, align 4
  store atomic i32 2, ptr addrspace(1) %p2 unordered, align 4
  store atomic i32 3, ptr addrspace(1) %p3 unordered, align 4
  store atomic i32 4, ptr addrspace(1) %p4 unordered, align 4
  br label %do_copy
do_copy:
  invoke void @jeandle.copy(ptr addrspace(1) %a, i64 1, ptr addrspace(1) %a, i64 0, i64 3,
                            ptr null, ptr null, i64 4, i64 4)
      #0 [ "deopt"(i32 99, i32 99, i64 12, ptr addrspace(1) null) ]
      to label %post_store unwind label %u
post_store:
  store atomic i32 9, ptr addrspace(1) %p2 unordered, align 4
  br label %value_based
value_based:
  %vb = call hotspotcc i1 @jeandle.check_if_value_based(ptr addrspace(1) %a)
  call void @sink_i1(i1 %vb)
  br label %read
read:
  %q0 = getelementptr inbounds i8, ptr addrspace(1) %a, i64 16
  %v0 = load atomic i32, ptr addrspace(1) %q0 unordered, align 4
  ret i32 %v0
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

attributes #0 = { "jeandle.copy.kind"="arraycopy" "jeandle.copy.validated" }

attributes #1 = { "jeandle.copy.kind"="clone-instance" "jeandle.copy.tightly-coupled-allocation" }

; The intersection stores (2 at +20, 3 at +24) are read by the revived copy
; and must survive; the destination-only store (1 at +16) is overwritten and
; stays dead; 4 at +28 sits outside the destination window.
; CHECK-LABEL: define i32 @selfoverlap_drop_reaching_defs
; CHECK: %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_array
; CHECK-NOT: store atomic i32 1,
; CHECK: store atomic i32 2, ptr addrspace(1)
; CHECK: store atomic i32 3, ptr addrspace(1)
; CHECK: store atomic i32 4, ptr addrspace(1)
; CHECK: invoke void @jeandle.copy(ptr addrspace(1) %a, i64 1, ptr addrspace(1) %a, i64 0, i64 3
; CHECK: call hotspotcc i1 @jeandle.check_if_value_based(ptr addrspace(1) %a)
; CHECK: ret i32

; The source's store 7 is restored at its original position (before the
; revived call), so the copy reads it — not the later replay.
; CHECK-LABEL: define i32 @v2v_late_src_escape_drop
; CHECK: %src = invoke hotspotcc ptr addrspace(1) @jeandle.new_array
; CHECK: %sx = getelementptr inbounds i8, ptr addrspace(1) %src, i64 16
; CHECK: store atomic i32 7, ptr addrspace(1) %sx
; CHECK: %dst = invoke hotspotcc ptr addrspace(1) @jeandle.new_array
; CHECK: invoke void @jeandle.copy(ptr addrspace(1) %src, i64 0, ptr addrspace(1) %dst, i64 0, i64 2
; CHECK: call hotspotcc i1 @jeandle.check_if_value_based(ptr addrspace(1) %dst)
; CHECK: call void @sink(ptr addrspace(1) %src)
; CHECK: ret i32


; Both source stores return: 7 (pre-copy, observed at the fold before the
; post-copy store killed its entry) and 42 (post-copy), and the revived
; call reads the pre-copy value.
; CHECK-LABEL: define i32 @v2v_postcopy_store_drop
; CHECK: store atomic i32 7, ptr addrspace(1)
; CHECK: invoke void @jeandle.copy(ptr addrspace(1) %src, i64 0, ptr addrspace(1) %dst, i64 0, i64 2
; CHECK: store atomic i32 42, ptr addrspace(1)
; CHECK: call hotspotcc i1 @jeandle.check_if_value_based(ptr addrspace(1) %dst)
; CHECK: ret i32

; The intersection store 2 survives the killing store 9; the
; destination-only store 1 stays dead.
; CHECK-LABEL: define i32 @selfoverlap_postcopy_store_drop
; CHECK-NOT: store atomic i32 1,
; CHECK: store atomic i32 2, ptr addrspace(1)
; CHECK: store atomic i32 3, ptr addrspace(1)
; CHECK: store atomic i32 4, ptr addrspace(1)
; CHECK: invoke void @jeandle.copy(ptr addrspace(1) %a, i64 1, ptr addrspace(1) %a, i64 0, i64 3
; CHECK: store atomic i32 9, ptr addrspace(1)
; CHECK: ret i32

!java-method-compilation = !{}
