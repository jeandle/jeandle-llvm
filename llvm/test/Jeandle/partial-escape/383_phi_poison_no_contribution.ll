; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Poison is a refinement wildcard while resolving a Select. A
; `select i1 %c, ptr alloc, ptr poison` therefore refines to the allocation's
; defined identity. Freeze preserves that successfully resolved identity.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare i32 @__gxx_personality_v0(...)

define i32 @t(i1 %c) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %n unwind label %u
n:
  %s0 = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  store atomic i32 77, ptr addrspace(1) %s0 unordered, align 4
  ; Select between virtual and poison. resolveVirtualRef must see through
  ; to the virtual.
  %sel = select i1 %c, ptr addrspace(1) %o, ptr addrspace(1) poison
  %frozen = freeze ptr addrspace(1) %sel
  %s1 = getelementptr inbounds i8, ptr addrspace(1) %frozen, i64 8
  %v = load atomic i32, ptr addrspace(1) %s1 unordered, align 4
  ret i32 %v
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define i32 @t
; CHECK-NOT: jeandle.new_instance
; CHECK-NOT: store atomic
; CHECK-NOT: load atomic
; CHECK: ret i32 77

!java-method-compilation = !{}
