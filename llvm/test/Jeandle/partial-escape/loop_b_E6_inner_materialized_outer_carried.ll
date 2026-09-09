; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Mixed nested convergence: the OUTER loop carries a virtual %o (field
; mutated in the inner body, folds to %i), while the INNER loop has a
; loop-local allocation %p that ESCAPES via @sink every inner iteration and
; is therefore MATERIALIZED (survives). Exercises the inner fixpoint with a
; materialized virtual coexisting with an outer-loop carried virtual that
; still converges on a stable header merged state B.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @use(i32)
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @test_inner_materialized_outer_carried(i32 %n, i32 %m) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 40901 to ptr), i32 16, i1 false)
       to label %prep unwind label %u
prep:
  %s = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  store atomic i32 1, ptr addrspace(1) %s unordered, align 4
  br label %oloop
oloop:
  %i = phi i32 [ 0, %prep ], [ %i2, %oend ]
  %ci = icmp slt i32 %i, %n
  br i1 %ci, label %obody, label %oexit
obody:
  br label %iloop
iloop:
  %j = phi i32 [ 0, %obody ], [ %j1, %ist ]
  %cj = icmp slt i32 %j, %m
  br i1 %cj, label %ibody, label %oend
ibody:
  %p = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 40902 to ptr), i32 16, i1 false)
       to label %ist unwind label %u
ist:
  call void @sink(ptr addrspace(1) %p)
  store atomic i32 %i, ptr addrspace(1) %s unordered, align 4
  %v = load atomic i32, ptr addrspace(1) %s unordered, align 4
  call void @use(i32 %v)
  %j1 = add i32 %j, 1
  br label %iloop
oend:
  %i2 = add i32 %i, 1
  br label %oloop
oexit:
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; The inner escapee %p (klass 40902) is materialized and survives; @sink sees it.
; The outer carried %o (klass 40901) is eliminated and its load folds to %i.
; CHECK-LABEL: define void @test_inner_materialized_outer_carried
; CHECK: invoke {{.*}}@jeandle.new_instance({{.*}}i64 40902
; CHECK: call void @sink
; CHECK-NOT: i64 40901
; CHECK-NOT: store atomic
; CHECK: call void @use(i32 %i)

!java-method-compilation = !{}
