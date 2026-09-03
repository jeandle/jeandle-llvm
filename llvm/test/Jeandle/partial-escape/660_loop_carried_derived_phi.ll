; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; A pointer PHI carries a virtual object around a loop with a DERIVED
; (non-zero offset) back-edge value. The iter-0 header merge optimistically
; takes Case B, but the first pass with back-edge data sees the +8 carry,
; which a whole-object alias cannot represent: the decision flips to Case A
; and the object is materialized. The allocation and the derived-pointer
; accesses survive — no poison may leak into the loop.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink_i32(i32)
declare i32 @__gxx_personality_v0(...)

define void @loop_carried_derived_phi(i32 %n) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 6662 to ptr), i32 32, i1 false)
       to label %prep unwind label %u
prep:
  br label %loop
loop:
  %i = phi i32 [ 0, %prep ], [ %inc, %loop ]
  %p = phi ptr addrspace(1) [ %o, %prep ], [ %obc, %loop ]
  %f = getelementptr inbounds i8, ptr addrspace(1) %p, i64 16
  store i32 7, ptr addrspace(1) %f
  %v = load i32, ptr addrspace(1) %f
  call void @sink_i32(i32 %v)
  %obc = getelementptr inbounds i8, ptr addrspace(1) %p, i64 8
  %inc = add nuw i32 %i, 1
  %cmp = icmp ult i32 %inc, %n
  br i1 %cmp, label %loop, label %exit
exit:
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; The object is materialized: the original allocation survives and the
; field store stays a real store. No operand may turn into poison.
; CHECK-LABEL: define void @loop_carried_derived_phi
; CHECK: %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK-NOT: poison
; CHECK: store i32 7, ptr addrspace(1) %f
; CHECK: %v = load i32, ptr addrspace(1) %f

!java-method-compilation = !{}
