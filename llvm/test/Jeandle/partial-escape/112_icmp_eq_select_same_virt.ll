; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Select whose two arms are aliased to the same virtual.
; processInstruction dispatches SelectInst into propagatePointerAlias,
; which uses resolveVirtualRef's Select case to verify that both arms
; resolve to the same ObjectID and then aliases the Select to that
; virtual. The icmp eq downstream resolves both operands to the same
; ObjectID and folds to true; the diff arm becomes unreachable and the
; allocation is eliminated.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @use(i32)
declare i32 @__gxx_personality_v0(...)

define void @test_icmp_eq_select_same_virt(i1 %c)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %n unwind label %u
n:
  %sel = select i1 %c, ptr addrspace(1) %o, ptr addrspace(1) %o
  %eq = icmp eq ptr addrspace(1) %sel, %o
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

; Expected behavior:
;   - propagatePointerAlias aliases %sel to the same ObjectID as %o.
;   - icmp eq sees both operands resolve to that ObjectID -> folds to true.
;   - transform replaces the conditional branch with an unconditional one
;     to %same, %diff becomes unreachable and is pruned.
;   - With no surviving consumer the allocation is eliminated.
; CHECK-LABEL: define void @test_icmp_eq_select_same_virt
; CHECK-NOT: @jeandle.new_instance
; CHECK-NOT: pea.mat
; CHECK-NOT: select
; CHECK: call void @use(i32 1)
; CHECK-NOT: call void @use(i32 -1)

!java-method-compilation = !{}
