; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; A three-way PHI whose incomings all alias to the same
; virtual. processBlockPhis Case B already covers this at the merge
; block (because the AliasMap has all three incomings registered for
; the same ObjectID), so resolveVirtualRef's PHINode case is a
; redundant safety net here; the test pins the end-to-end fold
; regardless of which path resolves first.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @use(i32)
declare i32 @__gxx_personality_v0(...)

define void @test_three_way_phi_same(i32 %k)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %n unwind label %u
n:
  switch i32 %k, label %a [ i32 1, label %b
                            i32 2, label %c ]
a:
  br label %merge
b:
  br label %merge
c:
  br label %merge
merge:
  %phi = phi ptr addrspace(1) [ %o, %a ], [ %o, %b ], [ %o, %c ]
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

; All three incomings are %o (same ObjectID) -> Case B aliases the PHI;
; icmp eq folds; alloc eliminated.
; CHECK-LABEL: define void @test_three_way_phi_same
; CHECK-NOT: @jeandle.new_instance
; CHECK-NOT: pea.mat
; CHECK: call void @use(i32 1)
; CHECK-NOT: call void @use(i32 -1)

!java-method-compilation = !{}
