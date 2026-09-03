; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Rewrite-clone then EliminateAllocation on the SAME allocation invoke:
; %b is described with %a in its deopt bundle (Pass 1
; clones %b's invoke with the descriptor), and %b itself is NeverEscapes
; (Pass 2 erases the clone via the WeakTrackingVH Target that followed the
; RAUW). Pre-VH-hardening this double-touched the freed original invoke.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare i32 @__gxx_personality_v0(...)

define void @both_neverescape() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 100 to ptr), i32 16, i1 false)
       to label %n1 unwind label %u
n1:
  %b = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 200 to ptr), i32 16, i1 false)
       [ "deopt"(i32 99, i32 99, i64 12, ptr addrspace(1) %a) ]
       to label %n2 unwind label %u
n2:
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; Both VOs are NeverEscapes: the descriptor died with %b's bundle; both
; invokes are gone. Clean, no crash, no poison.
; CHECK-LABEL: define void @both_neverescape(
; CHECK-NOT: jeandle.new_instance
; CHECK: ret void
; CHECK-NOT: poison

!java-method-compilation = !{}
