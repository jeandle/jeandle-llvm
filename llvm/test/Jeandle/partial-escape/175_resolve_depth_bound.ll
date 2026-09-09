; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; A long Select chain. The depth cap in
; resolveVirtualRef is 8; this chain is exactly 8 selects deep
; (depth 9 total counting the outermost). When the Select case
; dispatches, processBlockPhis Case B (and selects aliased by
; propagatePointerAlias as the analyzer walks each Select in IR order)
; mean the AliasMap is populated incrementally — by the time the
; outermost Select is queried, all inner Selects are already aliased
; to the virtual, so the alias-first check short-circuits at depth 1
; and the recursion never approaches the cap.
;
; The test is a stress-test for the contract that a deep chain DOES
; resolve (because of the incremental aliasing), and that even if it
; didn't, the depth bound would prevent any crash or runaway.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @use(i32)
declare i32 @__gxx_personality_v0(...)

define void @test_depth_bound(i1 %c)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %n unwind label %u
n:
  %s1 = select i1 %c, ptr addrspace(1) %o, ptr addrspace(1) %o
  %s2 = select i1 %c, ptr addrspace(1) %s1, ptr addrspace(1) %s1
  %s3 = select i1 %c, ptr addrspace(1) %s2, ptr addrspace(1) %s2
  %s4 = select i1 %c, ptr addrspace(1) %s3, ptr addrspace(1) %s3
  %s5 = select i1 %c, ptr addrspace(1) %s4, ptr addrspace(1) %s4
  %s6 = select i1 %c, ptr addrspace(1) %s5, ptr addrspace(1) %s5
  %s7 = select i1 %c, ptr addrspace(1) %s6, ptr addrspace(1) %s6
  %s8 = select i1 %c, ptr addrspace(1) %s7, ptr addrspace(1) %s7
  %eq = icmp eq ptr addrspace(1) %s8, %o
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

; All Selects collapse, alloc eliminated.
; CHECK-LABEL: define void @test_depth_bound
; CHECK-NOT: @jeandle.new_instance
; CHECK-NOT: pea.mat
; CHECK-NOT: select
; CHECK: call void @use(i32 1)
; CHECK-NOT: call void @use(i32 -1)

!java-method-compilation = !{}
