; RUN: opt -S -verify-each -passes="partial-escape-iterative" %s | FileCheck %s

; Exercise both outcomes of the same AS3 Case-C shape. An escaping synthetic
; needs a separate AS1 replay identity and keeps its per-edge sources real. A
; non-escaping synthetic instead folds its scalar load and eliminates all
; object memory traffic without creating a replay identity.
target datalayout = "e-p:64:64-p1:64:64-p3:32:32"

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @consume(ptr addrspace(1))
declare void @path_effect(i32)
declare i32 @__gxx_personality_v0(...)

define void @narrow_casec_replay_identity(i1 %choose, i32 %left.value,
                                          i32 %right.value)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  br i1 %choose, label %left, label %right

left:
  %left.obj = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 76601 to ptr), i32 24, i1 false)
      to label %left.init unwind label %unwind

left.init:
  %left.narrow = addrspacecast ptr addrspace(1) %left.obj to ptr addrspace(3)
  %left.self.slot = getelementptr inbounds i8, ptr addrspace(1) %left.obj, i64 16
  store atomic ptr addrspace(3) %left.narrow, ptr addrspace(1) %left.self.slot unordered, align 4
  %left.slot = getelementptr inbounds i8, ptr addrspace(1) %left.obj, i64 12
  store atomic i32 %left.value, ptr addrspace(1) %left.slot unordered, align 4
  call void @path_effect(i32 %left.value)
  br label %merge

right:
  %right.obj = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 76601 to ptr), i32 24, i1 false)
      to label %right.init unwind label %unwind

right.init:
  %right.narrow = addrspacecast ptr addrspace(1) %right.obj to ptr addrspace(3)
  %right.self.slot = getelementptr inbounds i8, ptr addrspace(1) %right.obj, i64 16
  store atomic ptr addrspace(3) %right.narrow, ptr addrspace(1) %right.self.slot unordered, align 4
  %right.slot = getelementptr inbounds i8, ptr addrspace(1) %right.obj, i64 12
  store atomic i32 %right.value, ptr addrspace(1) %right.slot unordered, align 4
  call void @path_effect(i32 %right.value)
  br label %merge

merge:
  %merged.narrow = phi ptr addrspace(3) [ %left.narrow, %left.init ],
                                           [ %right.narrow, %right.init ]
  %merged = addrspacecast ptr addrspace(3) %merged.narrow to ptr addrspace(1)
  call void @consume(ptr addrspace(1) %merged)
  ret void

unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

define i32 @narrow_casec_scalar_elimination(i1 %choose, i32 %left.value,
                                             i32 %right.value)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  br i1 %choose, label %left, label %right

left:
  %left.obj = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 76701 to ptr), i32 24, i1 false)
      to label %left.init unwind label %unwind

left.init:
  %left.narrow = addrspacecast ptr addrspace(1) %left.obj to ptr addrspace(3)
  %left.self.slot = getelementptr inbounds i8, ptr addrspace(1) %left.obj, i64 16
  store atomic ptr addrspace(3) %left.narrow, ptr addrspace(1) %left.self.slot unordered, align 4
  %left.slot = getelementptr inbounds i8, ptr addrspace(1) %left.obj, i64 12
  store atomic i32 %left.value, ptr addrspace(1) %left.slot unordered, align 4
  call void @path_effect(i32 %left.value)
  br label %merge

right:
  %right.obj = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 76701 to ptr), i32 24, i1 false)
      to label %right.init unwind label %unwind

right.init:
  %right.narrow = addrspacecast ptr addrspace(1) %right.obj to ptr addrspace(3)
  %right.self.slot = getelementptr inbounds i8, ptr addrspace(1) %right.obj, i64 16
  store atomic ptr addrspace(3) %right.narrow, ptr addrspace(1) %right.self.slot unordered, align 4
  %right.slot = getelementptr inbounds i8, ptr addrspace(1) %right.obj, i64 12
  store atomic i32 %right.value, ptr addrspace(1) %right.slot unordered, align 4
  call void @path_effect(i32 %right.value)
  br label %merge

merge:
  %merged.narrow = phi ptr addrspace(3) [ %left.narrow, %left.init ],
                                           [ %right.narrow, %right.init ]
  %merged = addrspacecast ptr addrspace(3) %merged.narrow to ptr addrspace(1)
  %merged.slot = getelementptr inbounds i8, ptr addrspace(1) %merged, i64 12
  %result = load atomic i32, ptr addrspace(1) %merged.slot unordered, align 4
  ret i32 %result

unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}


!java-method-compilation = !{}

; CHECK-LABEL: define void @narrow_casec_replay_identity
; CHECK-COUNT-2: @jeandle.new_instance
; CHECK-NOT: phi ptr addrspace(3)
; CHECK: %[[FIELD:pea.casec.field.phi[^ ]*]] = phi i32
; CHECK-NOT: phi ptr addrspace(3)
; CHECK: %[[REPLAY:pea.casec.replay.phi[^ ]*]] = phi ptr addrspace(1)
; CHECK: %[[VALUE_SLOT:pea.matslot[^ ]*]] = getelementptr inbounds{{( nuw)?}} i8, ptr addrspace(1) %[[REPLAY]], i64 12
; CHECK-NEXT: store atomic i32 %[[FIELD]], ptr addrspace(1) %[[VALUE_SLOT]] unordered, align 4
; CHECK: %[[ENCODE:pea.encode.oop[^ ]*]] = addrspacecast ptr addrspace(1) %[[REPLAY]] to ptr addrspace(3)
; CHECK-NEXT: %[[SELF_SLOT:pea.matslot[^ ]*]] = getelementptr inbounds{{( nuw)?}} i8, ptr addrspace(1) %[[REPLAY]], i64 16
; CHECK-NEXT: store atomic ptr addrspace(3) %[[ENCODE]], ptr addrspace(1) %[[SELF_SLOT]] unordered, align 4
; CHECK-NOT: phi ptr addrspace(3)
; CHECK: call void @consume(ptr addrspace(1) %[[REPLAY]])

; CHECK-LABEL: define i32 @narrow_casec_scalar_elimination
; CHECK-NOT: @jeandle.new_instance
; CHECK-NOT: pea.casec.replay.phi
; CHECK-NOT: phi ptr addrspace(3)
; CHECK-NOT: store atomic
; CHECK-NOT: load atomic
; CHECK: %[[SCALAR:pea.casec.field.phi[^ ]*]] = phi i32
; CHECK-NOT: @jeandle.new_instance
; CHECK-NOT: pea.casec.replay.phi
; CHECK-NOT: phi ptr addrspace(3)
; CHECK-NOT: store atomic
; CHECK-NOT: load atomic
; CHECK: ret i32 %[[SCALAR]]
