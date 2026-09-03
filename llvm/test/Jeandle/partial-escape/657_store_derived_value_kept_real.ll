; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Storing a DERIVED pointer to a virtual object into another virtual
; object's field must not be recorded as a whole-object VirtualRef:
; resolveVirtualRef returns the inner object's identity but discards the
; byte offset, so `store ptr gep(%inner, 8), ptr gep(%outer, 16)` would
; silently lose the +8 — a later load of the field would fold to the
; inner's base pointer. The store must survive, with both objects
; materialized at the store.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @store_derived_value(i1 %c) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %inner = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
               ptr inttoptr (i64 7778 to ptr), i32 32, i1 false)
           to label %n1 unwind label %u
n1:
  %outer = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
               ptr inttoptr (i64 7779 to ptr), i32 32, i1 false)
           to label %n2 unwind label %u
n2:
  %slot = getelementptr inbounds i8, ptr addrspace(1) %inner, i64 8
  %field = getelementptr inbounds i8, ptr addrspace(1) %outer, i64 16
  store ptr addrspace(1) %slot, ptr addrspace(1) %field
  %v = load ptr addrspace(1), ptr addrspace(1) %field
  call void @sink(ptr addrspace(1) %v)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; Both allocations and the store survive; the load is a real load of the
; stored derived pointer (NOT folded to the inner object's base).
; CHECK-LABEL: define void @store_derived_value
; CHECK: %inner = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK: %outer = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK: %slot = getelementptr inbounds i8, ptr addrspace(1) %inner, i64 8
; CHECK: store ptr addrspace(1) %slot, ptr addrspace(1) %field
; CHECK: %v = load ptr addrspace(1), ptr addrspace(1) %field
; CHECK-NOT: store ptr addrspace(1) poison
; CHECK: call void @sink(ptr addrspace(1) %v)

!java-method-compilation = !{}
