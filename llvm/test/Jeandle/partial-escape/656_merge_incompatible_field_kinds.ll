; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Two predecessors store values of incompatible primitive kinds (same byte
; size, different LLVM types) at the same field offset. The entries cannot
; merge into one field-PHI type, so — as an incompatible merge —
; the object is materialized at EVERY predecessor and
; the load stays a real load. Dropping just the offending offset would
; silently lose the eliminated stores and fold the load to the Java
; default 0.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink_i32(i32)
declare i32 @__gxx_personality_v0(...)

define void @merge_incompatible_fields(i1 %c) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 7777 to ptr), i32 32, i1 false)
       to label %cont unwind label %u
cont:
  br i1 %c, label %a, label %b
a:
  %fa = getelementptr inbounds i8, ptr addrspace(1) %o, i64 16
  store i32 5, ptr addrspace(1) %fa
  br label %m
b:
  %fb = getelementptr inbounds i8, ptr addrspace(1) %o, i64 16
  store float 1.000000e+00, ptr addrspace(1) %fb
  br label %m
m:
  %fm = getelementptr inbounds i8, ptr addrspace(1) %o, i64 16
  %v = load i32, ptr addrspace(1) %fm
  call void @sink_i32(i32 %v)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; The object is materialized at both predecessors: the original allocation
; survives, both stores are replayed onto it, and the load is a real load
; (NOT folded to the default 0).
; CHECK-LABEL: define void @merge_incompatible_fields
; CHECK: %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK: store atomic i32 5, ptr addrspace(1) %pea.matslot{{[0-9]*}} unordered, align 4
; CHECK: store atomic float 1.000000e+00, ptr addrspace(1) %pea.matslot{{[0-9]*}} unordered, align 4
; CHECK: %v = load i32, ptr addrspace(1) %fm
; CHECK-NOT: call void @sink_i32(i32 0)
; CHECK: call void @sink_i32(i32 %v)

!java-method-compilation = !{}
