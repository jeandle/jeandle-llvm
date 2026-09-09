; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; A PHI mixing a virtual incoming with a non-virtual
; incoming (a function-argument pointer). resolveVirtualRef returns
; nullopt because one arm resolves to None. processBlockPhis Case A
; handles this at the merge (per-pred materialization of the virtual
; arm); resolveVirtualRef's PHI case must agree by NOT
; pretending the PHI is fully virtual at downstream consumers.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @use(i32)
declare i32 @__gxx_personality_v0(...)

define void @test_phi_mixed(i1 %c, ptr addrspace(1) %arg)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  br i1 %c, label %left, label %right
left:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %l_cont unwind label %u
l_cont:
  br label %merge
right:
  br label %merge
merge:
  %phi = phi ptr addrspace(1) [ %o, %l_cont ], [ %arg, %right ]
  ; This icmp eq must NOT fold to true: %phi might be %arg, which is a
  ; distinct identity from %o on the right path. The PHI cannot resolve
  ; to %o's ObjectID alone — Case A applies, %o gets materialized at
  ; %l_cont's terminator.
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

; Alloc must be materialized; both arms of the icmp must remain
; reachable.
; CHECK-LABEL: define void @test_phi_mixed
; CHECK: @jeandle.new_instance
; CHECK-DAG: call void @use(i32 1)
; CHECK-DAG: call void @use(i32 -1)

!java-method-compilation = !{}
