; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; A stored value that resolves to a virtual object by IDENTITY but is not
; address-equal to it on every path — a freeze of a select between two
; different derived pointers — must not be recorded as a whole-object
; VirtualRef. resolveFieldOffset has no Select case (it returns 0 through
; the freeze), so only a recursive whole-object check (Select arms and PHI
; incomings) catches this shape. The select itself is not whole-object
; either (both arms are derived GEPs), so the generic escape path
; MATERIALIZES %inner at the select: %inner's
; allocation survives and the derived arms stay valid. The store of %fr
; then tracks a live materialized value, the load folds to %fr (NOT to
; %inner's base — the offset-losing regression this test guards), and
; %outer is eliminated.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @store_freeze_select_derived(i1 %c) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %inner = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
               ptr inttoptr (i64 7780 to ptr), i32 32, i1 false)
           to label %n1 unwind label %u
n1:
  %outer = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
               ptr inttoptr (i64 7781 to ptr), i32 32, i1 false)
           to label %n2 unwind label %u
n2:
  %g1 = getelementptr inbounds i8, ptr addrspace(1) %inner, i64 8
  %g2 = getelementptr inbounds i8, ptr addrspace(1) %inner, i64 16
  %sel = select i1 %c, ptr addrspace(1) %g1, ptr addrspace(1) %g2
  %fr = freeze ptr addrspace(1) %sel
  %field = getelementptr inbounds i8, ptr addrspace(1) %outer, i64 24
  store ptr addrspace(1) %fr, ptr addrspace(1) %field
  %v = load ptr addrspace(1), ptr addrspace(1) %field
  call void @sink(ptr addrspace(1) %v)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; %inner's allocation survives (materialized at the select); the select and
; freeze stay real over the derived pointers; the load folds to the stored
; %fr; %outer's allocation, the store and the load are eliminated.
; CHECK-LABEL: define void @store_freeze_select_derived
; CHECK: %inner = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK-NOT: new_instance
; CHECK: %sel = select i1 %c, ptr addrspace(1) %g1, ptr addrspace(1) %g2
; CHECK: %fr = freeze ptr addrspace(1) %sel
; CHECK: call void @sink(ptr addrspace(1) %fr)
; CHECK-NOT: store ptr addrspace(1) poison

!java-method-compilation = !{}
