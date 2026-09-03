; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; A Select between two arms both aliased to the same virtual ObjectID.
; resolveVirtualRef recurses through Select arms,
; both resolve to the same ID, propagatePointerAlias aliases the Select
; itself to the virtual, downstream consumers fold, and the alloc is
; eliminated. Same fold as test 112 but exercised
; without the invoke/unwind framing for a tighter check.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @use(i32)
declare i32 @__gxx_personality_v0(...)

define void @test_select_same_virt(i1 %c)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %n unwind label %u
n:
  ; Both arms are literally the same SSA value — the simplest Select
  ; resolution.
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

; CHECK-LABEL: define void @test_select_same_virt
; CHECK-NOT: @jeandle.new_instance
; CHECK-NOT: pea.mat
; CHECK-NOT: select
; CHECK: call void @use(i32 1)
; CHECK-NOT: call void @use(i32 -1)

!java-method-compilation = !{}
