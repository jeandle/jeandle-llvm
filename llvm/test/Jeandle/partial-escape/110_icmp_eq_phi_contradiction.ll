; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Contradiction rule: a Case-B PHI carries the virtual ObjectID forward
; through both arms. Although the argument has no virtual identity, a
; still-virtual, newly allocated object cannot alias a pre-existing
; external value.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @use(i32)
declare i32 @__gxx_personality_v0(...)

define void @test_icmp_eq_phi_contradiction(i1 %c, ptr addrspace(1) nonnull %arg)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %n unwind label %u
n:
  br i1 %c, label %left, label %right
left:
  br label %merge
right:
  br label %merge
merge:
  %phi = phi ptr addrspace(1) [ %o, %left ], [ %o, %right ]
  %eq = icmp eq ptr addrspace(1) %phi, %arg
  br i1 %eq, label %same, label %diff
same:
  call void @use(i32 1)
  ret void
diff:
  call void @use(i32 -1)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; The target-relative distinctness proof folds the compare to false.
; CHECK-LABEL: define void @test_icmp_eq_phi_contradiction
; CHECK-NOT: @jeandle.new_instance
; CHECK-NOT: pea.mat
; CHECK: call void @use(i32 -1)
; CHECK-NOT: call void @use(i32 1)

!java-method-compilation = !{}
