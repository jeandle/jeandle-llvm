; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Edge case: a single virtual alloc flows through both arms of a
; branch unchanged. The merge block has phi(%o, %o); per Case B in
; processBlockPhis, the phi is aliased to the same virtual ObjectID
; as %o. Then `icmp eq %phi, %o` folds to true (same ID -> eq=true),
; the diff arm becomes unreachable, and the allocation is eliminated
; entirely.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @use(i32)
declare i32 @__gxx_personality_v0(...)

define void @test_icmp_eq_phi_case_b(i1 %c) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
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
  %eq = icmp eq ptr addrspace(1) %phi, %o
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

; Case B alias-of-virt is exploited end-to-end:
;   - processBlockPhis aliases %phi to the same ObjectID as %o.
;   - The icmp eq sees both operands resolve to that ObjectID and
;     folds to true; the transform replaces the conditional branch
;     with an unconditional one (-> %same).
;   - With no surviving consumer the allocation is eliminated.
;
; CHECK-LABEL: define void @test_icmp_eq_phi_case_b
; CHECK-NOT: @jeandle.new_instance
; CHECK-NOT: pea.mat
; CHECK: call void @use(i32 1)
; CHECK-NOT: call void @use(i32 -1)

!java-method-compilation = !{}
