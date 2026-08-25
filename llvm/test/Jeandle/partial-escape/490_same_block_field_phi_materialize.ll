; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; A merge field value is represented by an analyzer-built PHI.  When the
; object escapes later in that same merge block, CreatePHI must be applied
; before Materialize replays the merged value into the retained allocation.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @same_block_field_phi_materialize(i1 %c) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 100 to ptr), i32 16, i1 false)
       to label %n unwind label %u
n:
  %field = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  br i1 %c, label %t, label %f
t:
  store atomic i32 1, ptr addrspace(1) %field unordered, align 4
  br label %m
f:
  store atomic i32 2, ptr addrspace(1) %field unordered, align 4
  br label %m
m:
  call void @sink(ptr addrspace(1) %o)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @same_block_field_phi_materialize(
; CHECK: %pea.field.phi = phi i32 [ 2, %f ], [ 1, %t ]
; CHECK: %pea.matslot = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
; CHECK: store atomic i32 %pea.field.phi, ptr addrspace(1) %pea.matslot unordered, align 4
; CHECK: call void @sink(ptr addrspace(1) %o)
; CHECK-NOT: poison

!java-method-compilation = !{}
