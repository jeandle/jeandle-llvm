; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Value-side virtual leak in processStore.
; `store ptr %virt, ptr @G` where %virt is a virtual allocation but @G is a
; non-virtual global. processStore returns false on a non-virtual pointer;
; processInstruction falls through to materializeAllVirtualOperands and escapes
; the value side, so %virt is materialized at the store and the global
; receives the live materialized pointer. Without this, EliminateAllocation
; would RAUW %virt to PoisonValue and the surviving store would write
; `poison` into @G — observable global corruption.

@G = external global ptr addrspace(1)

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare i32 @__gxx_personality_v0(...)

define void @leak() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %v = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 24, i1 false)
       to label %n unwind label %u
n:
  store ptr addrspace(1) %v, ptr @G
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @leak
; The allocation survives because the value-side virtual escaped.
; CHECK: invoke{{.*}}@jeandle.new_instance
; CHECK: store ptr addrspace(1) %{{.*}}, ptr @G
; CHECK-NOT: store ptr addrspace(1) poison, ptr @G

!java-method-compilation = !{}
