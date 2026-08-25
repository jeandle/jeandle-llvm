; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; processStore with an unresolvable (symbolic-index) derived address on a
; virtual array, storing a virtual value that has its own tracked field
; store and folded load. A node whose virtualize() fails keeps its
; inputs and the generic escape path materializes them at the node. Here the array
; and the value both materialize AT the store: the value's tracked field
; store is replayed onto its OrigAlloc immediately before the symbolic
; store, the folded load stays folded, and the symbolic store survives
; writing the live value pointer. Regression guard: marking both objects
; ineligible instead would drop the folded load function-wide and leave the
; field store in place.

declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32)
declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @use_int(i32)
declare i32 @__gxx_personality_v0(...)

define void @test_symbolic_store(i64 %idx) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %arr = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
             ptr inttoptr (i64 22222 to ptr), i32 4, i32 32, i32 16, i32 1048576)
         to label %n1 unwind label %u
n1:
  %v = call hotspotcc ptr addrspace(1) @jeandle.new_instance(
           ptr inttoptr (i64 99999 to ptr), i32 24, i1 false)
  %f = getelementptr inbounds i8, ptr addrspace(1) %v, i64 8
  store atomic i32 66, ptr addrspace(1) %f unordered, align 4
  %r = load atomic i32, ptr addrspace(1) %f unordered, align 4
  call void @use_int(i32 %r)
  %base = getelementptr inbounds i8, ptr addrspace(1) %arr, i32 16
  %elem = getelementptr inbounds ptr addrspace(1), ptr addrspace(1) %base, i64 %idx
  store atomic ptr addrspace(1) %v, ptr addrspace(1) %elem unordered, align 4
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @test_symbolic_store
; Both allocations survive (both materialize at the symbolic store).
; CHECK: invoke hotspotcc ptr addrspace(1) @jeandle.new_array
; CHECK: call hotspotcc ptr addrspace(1) @jeandle.new_instance
; The folded load of %v's field STAYS folded (a bail would drop the fold
; function-wide and use_int would receive a real load).
; CHECK: call void @use_int(i32 66)
; %v's field store is replayed immediately before the symbolic store.
; CHECK: %pea.matslot = getelementptr inbounds i8, ptr addrspace(1) %v, i64 8
; CHECK: store atomic i32 66, ptr addrspace(1) %pea.matslot unordered, align 4
; The symbolic store survives and writes the live value pointer.
; CHECK: store atomic ptr addrspace(1) %v, ptr addrspace(1) %elem
; CHECK-NOT: poison

!java-method-compilation = !{}
