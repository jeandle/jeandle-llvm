; RUN: opt -S -verify-each \
; RUN:   -passes="require<partial-escape-analysis>,partial-escape-transform" \
; RUN:   %s | FileCheck %s

; A virtual holder contains an AS3 Case-C synthetic. Materializing the holder
; on one incoming of the final mixed merge recursively prepares the synthetic
; and creates its separate AS1 replay PHI. That materialization causes the
; final merge to retry. The replay-PHI shell must survive the retry because the
; synthetic VO and its monotonic effects retain pointers to it.

target datalayout = "e-p:64:64-p1:64:64-p3:32:32"

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @consume(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @narrow_replay_merge_retry_lifetime(
    i1 %choose, i1 %escape, ptr addrspace(1) %real,
    i32 %left.value, i32 %right.value)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %holder = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 76900 to ptr), i32 20, i1 false)
      to label %dispatch unwind label %unwind

dispatch:
  br i1 %choose, label %left, label %right

left:
  %left.obj = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 76901 to ptr), i32 16, i1 false)
      to label %left.init unwind label %unwind

left.init:
  %left.slot = getelementptr inbounds i8, ptr addrspace(1) %left.obj, i64 12
  store atomic i32 %left.value, ptr addrspace(1) %left.slot unordered, align 4
  %left.narrow = addrspacecast ptr addrspace(1) %left.obj to ptr addrspace(3)
  br label %casec

right:
  %right.obj = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 76901 to ptr), i32 16, i1 false)
      to label %right.init unwind label %unwind

right.init:
  %right.slot = getelementptr inbounds i8, ptr addrspace(1) %right.obj, i64 12
  store atomic i32 %right.value, ptr addrspace(1) %right.slot unordered, align 4
  %right.narrow = addrspacecast ptr addrspace(1) %right.obj to ptr addrspace(3)
  br label %casec

casec:
  %merged.narrow = phi ptr addrspace(3) [ %left.narrow, %left.init ],
                                           [ %right.narrow, %right.init ]
  %holder.slot = getelementptr inbounds i8, ptr addrspace(1) %holder, i64 12
  store atomic ptr addrspace(3) %merged.narrow,
      ptr addrspace(1) %holder.slot unordered, align 4
  br i1 %escape, label %virtual.path, label %real.path

virtual.path:
  br label %final

real.path:
  br label %final

final:
  %mixed = phi ptr addrspace(1) [ %holder, %virtual.path ],
                                  [ %real, %real.path ]
  call void @consume(ptr addrspace(1) %mixed)
  ret void

unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @narrow_replay_merge_retry_lifetime(
; CHECK-COUNT-3: @jeandle.new_instance
; CHECK: %[[REPLAY:pea.casec.replay.phi[^ ]*]] = phi ptr addrspace(1)
; CHECK: addrspacecast ptr addrspace(1) %[[REPLAY]] to ptr addrspace(3)
; CHECK: store atomic ptr addrspace(3)
; CHECK: call void @consume(ptr addrspace(1)

!java-method-compilation = !{}
