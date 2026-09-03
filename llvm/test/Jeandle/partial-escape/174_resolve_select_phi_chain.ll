; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Nested Select-of-PHI-of-virtual. The merge PHI itself
; gets aliased by processBlockPhis Case B; the downstream Select then
; resolves through resolveVirtualRef's Select case (each arm is
; %phi, which aliases to the virtual ID). Tests that recursion composes
; cleanly across both kinds of merges.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @use(i32)
declare i32 @__gxx_personality_v0(...)

define void @test_select_phi_chain(i1 %c1, i1 %c2)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %n unwind label %u
n:
  br i1 %c1, label %left, label %right
left:
  br label %merge
right:
  br label %merge
merge:
  ; Case B PHI: both incomings = %o.
  %phi = phi ptr addrspace(1) [ %o, %left ], [ %o, %right ]
  ; Select-of-PHI-of-virtual: both arms are %phi which aliases to %o's
  ; ObjectID. resolveVirtualRef Select case + Case B alias yield
  ; the same ObjectID for the Select.
  %sel = select i1 %c2, ptr addrspace(1) %phi, ptr addrspace(1) %phi
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

; Full fold through the chain.
; CHECK-LABEL: define void @test_select_phi_chain
; CHECK-NOT: @jeandle.new_instance
; CHECK-NOT: pea.mat
; CHECK: call void @use(i32 1)
; CHECK-NOT: call void @use(i32 -1)

!java-method-compilation = !{}
