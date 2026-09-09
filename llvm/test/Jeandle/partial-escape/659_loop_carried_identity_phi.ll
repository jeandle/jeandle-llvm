; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; A pointer PHI carries a virtual object around a loop with an IDENTITY
; (offset-0) back-edge value. The iter-0 header merge sees only the
; preheader incoming (the back edge has no exit data yet); treating the
; unresolved incoming as unknown — not as a divergence — takes Case B
; (the identity-singleton case), and the VO stays virtual
; across the whole loop: allocation, stores, loads and the PHI all fold
; away.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink_i32(i32)
declare i32 @__gxx_personality_v0(...)

define void @loop_carried_identity_phi(i32 %n) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 6661 to ptr), i32 32, i1 false)
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
  %obc = bitcast ptr addrspace(1) %p to ptr addrspace(1)
  %inc = add nuw i32 %i, 1
  %cmp = icmp ult i32 %inc, %n
  br i1 %cmp, label %loop, label %exit
exit:
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; The VO never escapes: the allocation is eliminated and the field
; store/load fold to the stored constant.
; CHECK-LABEL: define void @loop_carried_identity_phi
; CHECK-NOT: call hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK-NOT: store i32 7
; CHECK: call void @sink_i32(i32 7)
; CHECK-NOT: %v = load i32

!java-method-compilation = !{}
