; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; A Select between two arms that are different virtuals.
; resolveVirtualRef returns nullopt (different ObjectIDs do not
; merge), and propagatePointerAlias falls through to
; materializeAllVirtualOperands, forcing BOTH allocs to escape. The
; expected behavior is no crash, clean materialization of both allocs,
; and the Select left in place feeding a real-pointer icmp.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @use(i32)
declare i32 @__gxx_personality_v0(...)

define void @test_select_different_virts(i1 %c)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %n1 unwind label %u
n1:
  %b = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %n2 unwind label %u
n2:
  ; Different virtuals on each arm — Select cannot resolve.
  %sel = select i1 %c, ptr addrspace(1) %a, ptr addrspace(1) %b
  %eq = icmp eq ptr addrspace(1) %sel, %a
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

; Both allocs must be materialized; the Select survives. The icmp may
; or may not be folded by downstream passes — we don't pin it. The
; critical correctness check is: no analyzer crash and both allocs
; survive in IR.
; CHECK-LABEL: define void @test_select_different_virts
; CHECK-COUNT-2: @jeandle.new_instance
; CHECK: select

!java-method-compilation = !{}
