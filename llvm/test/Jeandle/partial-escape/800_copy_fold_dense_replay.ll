; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" -jeandle-vm-callback-log=%S/Inputs/770_copy_fold_v2v_full.cblog %s | FileCheck %s

; Dense large copies fold like any other: the destination's length is bounded
; by the array-virtualization cap, and the materialization replays the full
; entry set as a contiguous run of same-type unordered-atomic stores (the
; shape the auto-vectorizer widens once unordered atomics are vectorizable).
; Sparse windows replay only the tracked entries; default slots replay
; nothing; clone chains fold end to end.

declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32)
declare void @jeandle.copy(ptr addrspace(1), i64, ptr addrspace(1), i64, i64, ptr, ptr, i64, i64)
declare void @publish(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define i32 @sparse_escape() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %src = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 12345 to ptr), i32 16, i32 80, i32 16, i32 1048576)
      to label %init unwind label %u
init:
  %s0 = getelementptr inbounds i8, ptr addrspace(1) %src, i64 16
  store atomic i32 1, ptr addrspace(1) %s0 unordered, align 4
  %s1 = getelementptr inbounds i8, ptr addrspace(1) %src, i64 20
  store atomic i32 2, ptr addrspace(1) %s1 unordered, align 4
  %dst0 = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 12345 to ptr), i32 16, i32 80, i32 16, i32 1048576)
      to label %copy0 unwind label %u
copy0:
  invoke void @jeandle.copy(ptr addrspace(1) %src, i64 0, ptr addrspace(1) %dst0, i64 0, i64 16, ptr null, ptr null, i64 16, i64 16) #0
      to label %after0 unwind label %u
after0:
  call void @publish(ptr addrspace(1) %dst0)
  ret i32 0
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define i32 @sparse_escape(
; CHECK-NOT: jeandle.copy
; CHECK: call void @publish
; CHECK-NOT: jeandle.copy
; CHECK: ret i32 0

define i32 @dense_escape() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %src = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 12345 to ptr), i32 16, i32 80, i32 16, i32 1048576)
      to label %init unwind label %u
init:
  %s0 = getelementptr inbounds i8, ptr addrspace(1) %src, i64 16
  store atomic i32 1, ptr addrspace(1) %s0 unordered, align 4
  %s1 = getelementptr inbounds i8, ptr addrspace(1) %src, i64 20
  store atomic i32 2, ptr addrspace(1) %s1 unordered, align 4
  %s2 = getelementptr inbounds i8, ptr addrspace(1) %src, i64 24
  store atomic i32 3, ptr addrspace(1) %s2 unordered, align 4
  %s3 = getelementptr inbounds i8, ptr addrspace(1) %src, i64 28
  store atomic i32 4, ptr addrspace(1) %s3 unordered, align 4
  %s4 = getelementptr inbounds i8, ptr addrspace(1) %src, i64 32
  store atomic i32 5, ptr addrspace(1) %s4 unordered, align 4
  %s5 = getelementptr inbounds i8, ptr addrspace(1) %src, i64 36
  store atomic i32 6, ptr addrspace(1) %s5 unordered, align 4
  %s6 = getelementptr inbounds i8, ptr addrspace(1) %src, i64 40
  store atomic i32 7, ptr addrspace(1) %s6 unordered, align 4
  %s7 = getelementptr inbounds i8, ptr addrspace(1) %src, i64 44
  store atomic i32 8, ptr addrspace(1) %s7 unordered, align 4
  %s8 = getelementptr inbounds i8, ptr addrspace(1) %src, i64 48
  store atomic i32 9, ptr addrspace(1) %s8 unordered, align 4
  %s9 = getelementptr inbounds i8, ptr addrspace(1) %src, i64 52
  store atomic i32 10, ptr addrspace(1) %s9 unordered, align 4
  %s10 = getelementptr inbounds i8, ptr addrspace(1) %src, i64 56
  store atomic i32 11, ptr addrspace(1) %s10 unordered, align 4
  %s11 = getelementptr inbounds i8, ptr addrspace(1) %src, i64 60
  store atomic i32 12, ptr addrspace(1) %s11 unordered, align 4
  %s12 = getelementptr inbounds i8, ptr addrspace(1) %src, i64 64
  store atomic i32 13, ptr addrspace(1) %s12 unordered, align 4
  %s13 = getelementptr inbounds i8, ptr addrspace(1) %src, i64 68
  store atomic i32 14, ptr addrspace(1) %s13 unordered, align 4
  %s14 = getelementptr inbounds i8, ptr addrspace(1) %src, i64 72
  store atomic i32 15, ptr addrspace(1) %s14 unordered, align 4
  %s15 = getelementptr inbounds i8, ptr addrspace(1) %src, i64 76
  store atomic i32 16, ptr addrspace(1) %s15 unordered, align 4
  %dst0 = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 12345 to ptr), i32 16, i32 80, i32 16, i32 1048576)
      to label %copy0 unwind label %u
copy0:
  invoke void @jeandle.copy(ptr addrspace(1) %src, i64 0, ptr addrspace(1) %dst0, i64 0, i64 16, ptr null, ptr null, i64 16, i64 16) #0
      to label %after0 unwind label %u
after0:
  call void @publish(ptr addrspace(1) %dst0)
  ret i32 0
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define i32 @dense_escape(
; CHECK-NOT: jeandle.copy
; The full 16-entry window replays onto the materialized destination.
; CHECK-COUNT-16: store atomic i32
; CHECK: call void @publish
; CHECK: ret i32

define i32 @small_escape() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %src = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 12345 to ptr), i32 16, i32 80, i32 16, i32 1048576)
      to label %init unwind label %u
init:
  %s0 = getelementptr inbounds i8, ptr addrspace(1) %src, i64 16
  store atomic i32 1, ptr addrspace(1) %s0 unordered, align 4
  %s1 = getelementptr inbounds i8, ptr addrspace(1) %src, i64 20
  store atomic i32 2, ptr addrspace(1) %s1 unordered, align 4
  %s2 = getelementptr inbounds i8, ptr addrspace(1) %src, i64 24
  store atomic i32 3, ptr addrspace(1) %s2 unordered, align 4
  %s3 = getelementptr inbounds i8, ptr addrspace(1) %src, i64 28
  store atomic i32 4, ptr addrspace(1) %s3 unordered, align 4
  %s4 = getelementptr inbounds i8, ptr addrspace(1) %src, i64 32
  store atomic i32 5, ptr addrspace(1) %s4 unordered, align 4
  %s5 = getelementptr inbounds i8, ptr addrspace(1) %src, i64 36
  store atomic i32 6, ptr addrspace(1) %s5 unordered, align 4
  %s6 = getelementptr inbounds i8, ptr addrspace(1) %src, i64 40
  store atomic i32 7, ptr addrspace(1) %s6 unordered, align 4
  %s7 = getelementptr inbounds i8, ptr addrspace(1) %src, i64 44
  store atomic i32 8, ptr addrspace(1) %s7 unordered, align 4
  %s8 = getelementptr inbounds i8, ptr addrspace(1) %src, i64 48
  store atomic i32 9, ptr addrspace(1) %s8 unordered, align 4
  %s9 = getelementptr inbounds i8, ptr addrspace(1) %src, i64 52
  store atomic i32 10, ptr addrspace(1) %s9 unordered, align 4
  %s10 = getelementptr inbounds i8, ptr addrspace(1) %src, i64 56
  store atomic i32 11, ptr addrspace(1) %s10 unordered, align 4
  %s11 = getelementptr inbounds i8, ptr addrspace(1) %src, i64 60
  store atomic i32 12, ptr addrspace(1) %s11 unordered, align 4
  %s12 = getelementptr inbounds i8, ptr addrspace(1) %src, i64 64
  store atomic i32 13, ptr addrspace(1) %s12 unordered, align 4
  %s13 = getelementptr inbounds i8, ptr addrspace(1) %src, i64 68
  store atomic i32 14, ptr addrspace(1) %s13 unordered, align 4
  %s14 = getelementptr inbounds i8, ptr addrspace(1) %src, i64 72
  store atomic i32 15, ptr addrspace(1) %s14 unordered, align 4
  %s15 = getelementptr inbounds i8, ptr addrspace(1) %src, i64 76
  store atomic i32 16, ptr addrspace(1) %s15 unordered, align 4
  %dst0 = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 12345 to ptr), i32 16, i32 80, i32 16, i32 1048576)
      to label %copy0 unwind label %u
copy0:
  invoke void @jeandle.copy(ptr addrspace(1) %src, i64 0, ptr addrspace(1) %dst0, i64 0, i64 8, ptr null, ptr null, i64 16, i64 16) #0
      to label %after0 unwind label %u
after0:
  call void @publish(ptr addrspace(1) %dst0)
  ret i32 0
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define i32 @small_escape(
; CHECK-NOT: jeandle.copy
; CHECK: call void @publish
; CHECK-NOT: jeandle.copy
; CHECK: ret i32 0

define i32 @dense_clone_escape() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %src = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 12345 to ptr), i32 12, i32 64, i32 16, i32 1048576)
      to label %init unwind label %u
init:
  %s0 = getelementptr inbounds i8, ptr addrspace(1) %src, i64 16
  store atomic i32 1, ptr addrspace(1) %s0 unordered, align 4
  %s1 = getelementptr inbounds i8, ptr addrspace(1) %src, i64 20
  store atomic i32 2, ptr addrspace(1) %s1 unordered, align 4
  %s2 = getelementptr inbounds i8, ptr addrspace(1) %src, i64 24
  store atomic i32 3, ptr addrspace(1) %s2 unordered, align 4
  %s3 = getelementptr inbounds i8, ptr addrspace(1) %src, i64 28
  store atomic i32 4, ptr addrspace(1) %s3 unordered, align 4
  %s4 = getelementptr inbounds i8, ptr addrspace(1) %src, i64 32
  store atomic i32 5, ptr addrspace(1) %s4 unordered, align 4
  %s5 = getelementptr inbounds i8, ptr addrspace(1) %src, i64 36
  store atomic i32 6, ptr addrspace(1) %s5 unordered, align 4
  %s6 = getelementptr inbounds i8, ptr addrspace(1) %src, i64 40
  store atomic i32 7, ptr addrspace(1) %s6 unordered, align 4
  %s7 = getelementptr inbounds i8, ptr addrspace(1) %src, i64 44
  store atomic i32 8, ptr addrspace(1) %s7 unordered, align 4
  %s8 = getelementptr inbounds i8, ptr addrspace(1) %src, i64 48
  store atomic i32 9, ptr addrspace(1) %s8 unordered, align 4
  %s9 = getelementptr inbounds i8, ptr addrspace(1) %src, i64 52
  store atomic i32 10, ptr addrspace(1) %s9 unordered, align 4
  %s10 = getelementptr inbounds i8, ptr addrspace(1) %src, i64 56
  store atomic i32 11, ptr addrspace(1) %s10 unordered, align 4
  %s11 = getelementptr inbounds i8, ptr addrspace(1) %src, i64 60
  store atomic i32 12, ptr addrspace(1) %s11 unordered, align 4
  %dst0 = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 12345 to ptr), i32 12, i32 64, i32 16, i32 1048576)
      to label %copy0 unwind label %u
copy0:
  invoke void @jeandle.copy(ptr addrspace(1) %src, i64 8, ptr addrspace(1) %dst0, i64 8, i64 7, ptr null, ptr null, i64 12, i64 12) #1
      to label %after0 unwind label %u
after0:
  call void @publish(ptr addrspace(1) %dst0)
  ret i32 0
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define i32 @dense_clone_escape(
; CHECK-NOT: jeandle.copy
; All 12 cloned elements replay at the escape point.
; CHECK-COUNT-12: store atomic i32
; CHECK: call void @publish
; CHECK: ret i32

define i32 @mixed_folds() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %src = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 12345 to ptr), i32 16, i32 80, i32 16, i32 1048576)
      to label %init unwind label %u
init:
  %s0 = getelementptr inbounds i8, ptr addrspace(1) %src, i64 16
  store atomic i32 1, ptr addrspace(1) %s0 unordered, align 4
  %s1 = getelementptr inbounds i8, ptr addrspace(1) %src, i64 20
  store atomic i32 2, ptr addrspace(1) %s1 unordered, align 4
  %s2 = getelementptr inbounds i8, ptr addrspace(1) %src, i64 24
  store atomic i32 3, ptr addrspace(1) %s2 unordered, align 4
  %s3 = getelementptr inbounds i8, ptr addrspace(1) %src, i64 28
  store atomic i32 4, ptr addrspace(1) %s3 unordered, align 4
  %s4 = getelementptr inbounds i8, ptr addrspace(1) %src, i64 32
  store atomic i32 5, ptr addrspace(1) %s4 unordered, align 4
  %s5 = getelementptr inbounds i8, ptr addrspace(1) %src, i64 36
  store atomic i32 6, ptr addrspace(1) %s5 unordered, align 4
  %s6 = getelementptr inbounds i8, ptr addrspace(1) %src, i64 40
  store atomic i32 7, ptr addrspace(1) %s6 unordered, align 4
  %s7 = getelementptr inbounds i8, ptr addrspace(1) %src, i64 44
  store atomic i32 8, ptr addrspace(1) %s7 unordered, align 4
  %s8 = getelementptr inbounds i8, ptr addrspace(1) %src, i64 48
  store atomic i32 9, ptr addrspace(1) %s8 unordered, align 4
  %s9 = getelementptr inbounds i8, ptr addrspace(1) %src, i64 52
  store atomic i32 10, ptr addrspace(1) %s9 unordered, align 4
  %s10 = getelementptr inbounds i8, ptr addrspace(1) %src, i64 56
  store atomic i32 11, ptr addrspace(1) %s10 unordered, align 4
  %s11 = getelementptr inbounds i8, ptr addrspace(1) %src, i64 60
  store atomic i32 12, ptr addrspace(1) %s11 unordered, align 4
  %s12 = getelementptr inbounds i8, ptr addrspace(1) %src, i64 64
  store atomic i32 13, ptr addrspace(1) %s12 unordered, align 4
  %s13 = getelementptr inbounds i8, ptr addrspace(1) %src, i64 68
  store atomic i32 14, ptr addrspace(1) %s13 unordered, align 4
  %s14 = getelementptr inbounds i8, ptr addrspace(1) %src, i64 72
  store atomic i32 15, ptr addrspace(1) %s14 unordered, align 4
  %s15 = getelementptr inbounds i8, ptr addrspace(1) %src, i64 76
  store atomic i32 16, ptr addrspace(1) %s15 unordered, align 4
  %dst0 = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 12345 to ptr), i32 16, i32 80, i32 16, i32 1048576)
      to label %copy0 unwind label %u
copy0:
  invoke void @jeandle.copy(ptr addrspace(1) %src, i64 0, ptr addrspace(1) %dst0, i64 0, i64 16, ptr null, ptr null, i64 16, i64 16) #0
      to label %after0 unwind label %u
after0:
  call void @publish(ptr addrspace(1) %dst0)
  %local_src = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 12345 to ptr), i32 16, i32 80, i32 16, i32 1048576)
      to label %local_init unwind label %u
local_init:
  %local_first = getelementptr inbounds i8, ptr addrspace(1) %local_src, i64 16
  store atomic i32 3, ptr addrspace(1) %local_first unordered, align 4
  %tmp = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 12345 to ptr), i32 16, i32 80, i32 16, i32 1048576)
      to label %copy_tmp unwind label %u
copy_tmp:
  invoke void @jeandle.copy(ptr addrspace(1) %local_src, i64 0, ptr addrspace(1) %tmp, i64 0, i64 16, ptr null, ptr null, i64 16, i64 16) #0
      to label %read_tmp unwind label %u
read_tmp:
  %p = getelementptr inbounds i8, ptr addrspace(1) %tmp, i64 16
  %v = load atomic i32, ptr addrspace(1) %p unordered, align 4
  ret i32 %v
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define i32 @mixed_folds(
; Both copies fold independently; the never-escaping tail's read folds to
; the transferred constant.
; CHECK-NOT: jeandle.copy
; CHECK: call void @publish
; CHECK: ret i32 3

define i32 @clone_chain() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %src = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 12345 to ptr), i32 16, i32 80, i32 16, i32 1048576)
      to label %init unwind label %u
init:
  %s0 = getelementptr inbounds i8, ptr addrspace(1) %src, i64 16
  store atomic i32 1, ptr addrspace(1) %s0 unordered, align 4
  %s1 = getelementptr inbounds i8, ptr addrspace(1) %src, i64 20
  store atomic i32 2, ptr addrspace(1) %s1 unordered, align 4
  %s2 = getelementptr inbounds i8, ptr addrspace(1) %src, i64 24
  store atomic i32 3, ptr addrspace(1) %s2 unordered, align 4
  %s3 = getelementptr inbounds i8, ptr addrspace(1) %src, i64 28
  store atomic i32 4, ptr addrspace(1) %s3 unordered, align 4
  %s4 = getelementptr inbounds i8, ptr addrspace(1) %src, i64 32
  store atomic i32 5, ptr addrspace(1) %s4 unordered, align 4
  %s5 = getelementptr inbounds i8, ptr addrspace(1) %src, i64 36
  store atomic i32 6, ptr addrspace(1) %s5 unordered, align 4
  %s6 = getelementptr inbounds i8, ptr addrspace(1) %src, i64 40
  store atomic i32 7, ptr addrspace(1) %s6 unordered, align 4
  %s7 = getelementptr inbounds i8, ptr addrspace(1) %src, i64 44
  store atomic i32 8, ptr addrspace(1) %s7 unordered, align 4
  %s8 = getelementptr inbounds i8, ptr addrspace(1) %src, i64 48
  store atomic i32 9, ptr addrspace(1) %s8 unordered, align 4
  %s9 = getelementptr inbounds i8, ptr addrspace(1) %src, i64 52
  store atomic i32 10, ptr addrspace(1) %s9 unordered, align 4
  %s10 = getelementptr inbounds i8, ptr addrspace(1) %src, i64 56
  store atomic i32 11, ptr addrspace(1) %s10 unordered, align 4
  %s11 = getelementptr inbounds i8, ptr addrspace(1) %src, i64 60
  store atomic i32 12, ptr addrspace(1) %s11 unordered, align 4
  %s12 = getelementptr inbounds i8, ptr addrspace(1) %src, i64 64
  store atomic i32 13, ptr addrspace(1) %s12 unordered, align 4
  %s13 = getelementptr inbounds i8, ptr addrspace(1) %src, i64 68
  store atomic i32 14, ptr addrspace(1) %s13 unordered, align 4
  %s14 = getelementptr inbounds i8, ptr addrspace(1) %src, i64 72
  store atomic i32 15, ptr addrspace(1) %s14 unordered, align 4
  %s15 = getelementptr inbounds i8, ptr addrspace(1) %src, i64 76
  store atomic i32 16, ptr addrspace(1) %s15 unordered, align 4
  %dst0 = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 12345 to ptr), i32 16, i32 80, i32 16, i32 1048576)
      to label %copy0 unwind label %u
copy0:
  invoke void @jeandle.copy(ptr addrspace(1) %src, i64 8, ptr addrspace(1) %dst0, i64 8, i64 9, ptr null, ptr null, i64 16, i64 16) #1
      to label %after0 unwind label %u
after0:
  %dst1 = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 12345 to ptr), i32 16, i32 80, i32 16, i32 1048576)
      to label %copy1 unwind label %u
copy1:
  invoke void @jeandle.copy(ptr addrspace(1) %dst0, i64 8, ptr addrspace(1) %dst1, i64 8, i64 9, ptr null, ptr null, i64 16, i64 16) #1
      to label %after1 unwind label %u
after1:
  %dst2 = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 12345 to ptr), i32 16, i32 80, i32 16, i32 1048576)
      to label %copy2 unwind label %u
copy2:
  invoke void @jeandle.copy(ptr addrspace(1) %dst1, i64 8, ptr addrspace(1) %dst2, i64 8, i64 9, ptr null, ptr null, i64 16, i64 16) #1
      to label %after2 unwind label %u
after2:
  call void @publish(ptr addrspace(1) %dst2)
  ret i32 0
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define i32 @clone_chain(
; The whole chain folds; only the final clone's 9 tracked elements replay.
; CHECK-NOT: jeandle.copy
; CHECK-COUNT-9: store atomic i32
; CHECK: call void @publish
; CHECK: ret i32

define i32 @multiple_replay_sites(i1 %choose) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %src = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 12345 to ptr), i32 16, i32 80, i32 16, i32 1048576)
      to label %init unwind label %u
init:
  %s0 = getelementptr inbounds i8, ptr addrspace(1) %src, i64 16
  store atomic i32 1, ptr addrspace(1) %s0 unordered, align 4
  %dst = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 12345 to ptr), i32 16, i32 80, i32 16, i32 1048576)
      to label %copy unwind label %u
copy:
  invoke void @jeandle.copy(ptr addrspace(1) %src, i64 0, ptr addrspace(1) %dst, i64 0, i64 16, ptr null, ptr null, i64 16, i64 16) #0
      to label %branch unwind label %u
branch:
  br i1 %choose, label %sparse, label %dense
sparse:
  call void @publish(ptr addrspace(1) %dst)
  ret i32 0
dense:
  %d1 = getelementptr inbounds i8, ptr addrspace(1) %dst, i64 20
  store atomic i32 2, ptr addrspace(1) %d1 unordered, align 4
  %d2 = getelementptr inbounds i8, ptr addrspace(1) %dst, i64 24
  store atomic i32 3, ptr addrspace(1) %d2 unordered, align 4
  %d3 = getelementptr inbounds i8, ptr addrspace(1) %dst, i64 28
  store atomic i32 4, ptr addrspace(1) %d3 unordered, align 4
  %d4 = getelementptr inbounds i8, ptr addrspace(1) %dst, i64 32
  store atomic i32 5, ptr addrspace(1) %d4 unordered, align 4
  %d5 = getelementptr inbounds i8, ptr addrspace(1) %dst, i64 36
  store atomic i32 6, ptr addrspace(1) %d5 unordered, align 4
  %d6 = getelementptr inbounds i8, ptr addrspace(1) %dst, i64 40
  store atomic i32 7, ptr addrspace(1) %d6 unordered, align 4
  %d7 = getelementptr inbounds i8, ptr addrspace(1) %dst, i64 44
  store atomic i32 8, ptr addrspace(1) %d7 unordered, align 4
  %d8 = getelementptr inbounds i8, ptr addrspace(1) %dst, i64 48
  store atomic i32 9, ptr addrspace(1) %d8 unordered, align 4
  %d9 = getelementptr inbounds i8, ptr addrspace(1) %dst, i64 52
  store atomic i32 10, ptr addrspace(1) %d9 unordered, align 4
  call void @publish(ptr addrspace(1) %dst)
  ret i32 0
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define i32 @multiple_replay_sites(
; CHECK-NOT: jeandle.copy
; CHECK: call void @publish
; CHECK: ret i32 0

define i32 @empty_replay(i1 %choose) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %src = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 12345 to ptr), i32 16, i32 80, i32 16, i32 1048576)
      to label %init unwind label %u
init:
  %dst = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 12345 to ptr), i32 16, i32 80, i32 16, i32 1048576)
      to label %copy unwind label %u
copy:
  invoke void @jeandle.copy(ptr addrspace(1) %src, i64 0, ptr addrspace(1) %dst, i64 0, i64 16, ptr null, ptr null, i64 16, i64 16) #0
      to label %branch unwind label %u
branch:
  call void @publish(ptr addrspace(1) %dst)
  ret i32 0
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define i32 @empty_replay(
; CHECK-NOT: jeandle.copy
; CHECK: call void @publish
; CHECK-NOT: jeandle.copy
; CHECK: ret i32 0

attributes #0 = { "jeandle.copy.kind"="arraycopy" "jeandle.copy.validated" }
attributes #1 = { "jeandle.copy.kind"="clone-array" }

!java-method-compilation = !{}
