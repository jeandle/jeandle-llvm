; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; An outer virtual object holds a VirtualRef to an inner virtual object.
; The inner is then abandoned (kept real) because a DERIVED pointer to it
; escapes. When the outer later escapes, its materialization must still
; succeed — replaying the inner's surviving OrigAlloc into the field —
; instead of giving up on the outer too (the materialize commit contributes
; the already-materialized entry's value the same way).

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @foo(ptr addrspace(1))
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @outer_materializes_with_ineligible_inner() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %inner = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
               ptr inttoptr (i64 8881 to ptr), i32 32, i1 false)
           to label %n1 unwind label %u
n1:
  %outer = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
               ptr inttoptr (i64 8882 to ptr), i32 32, i1 false)
           to label %n2 unwind label %u
n2:
  %field = getelementptr inbounds i8, ptr addrspace(1) %outer, i64 16
  store ptr addrspace(1) %inner, ptr addrspace(1) %field
  ; Derived-pointer escape: keeps %inner real.
  %derived = getelementptr inbounds i8, ptr addrspace(1) %inner, i64 8
  call void @sink(ptr addrspace(1) %derived)
  ; The outer escapes here.
  call void @foo(ptr addrspace(1) %outer)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; Both allocations survive. The original store into %outer's field is
; eliminated and replayed at the escape point with the inner's real
; OrigAlloc as the value.
; CHECK-LABEL: define void @outer_materializes_with_ineligible_inner
; CHECK: %inner = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK: %outer = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK-NOT: store ptr addrspace(1) %inner, ptr addrspace(1) %field
; CHECK: %pea.matslot[[N:[0-9]*]] = getelementptr inbounds i8, ptr addrspace(1) %outer, i64 16
; CHECK: store atomic ptr addrspace(1) %inner, ptr addrspace(1) %pea.matslot[[N]] unordered, align 8
; CHECK: call void @foo(ptr addrspace(1) %outer)

!java-method-compilation = !{}
