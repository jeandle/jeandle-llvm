; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Companion of 388: %x escapes as a real call
; argument (materialized at foo), while %y — which only REFERENCES %x from a
; field and sits in foo's deopt bundle — stays VIRTUAL and is described with
; that field as a live oop (MaterializedRef -> describeMaterializedOop).
; updateOtherStatesForMaterialized flips %y's VirtualRef(%x) field to
; MaterializedRef(%x's OrigAlloc) when %x is materialized, so the descriptor
; carries the same real object the callee receives — one identity.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @foo(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @y_refs_x(i32 %v) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %x = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 11111 to ptr), i32 16, i1 false)
       to label %n1 unwind label %u
n1:
  %y = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 22222 to ptr), i32 16, i1 false)
       to label %n2 unwind label %u
n2:
  %yf = getelementptr inbounds i8, ptr addrspace(1) %y, i64 8
  store atomic ptr addrspace(1) %x, ptr addrspace(1) %yf unordered, align 8
  ; %x escapes as foo's argument (materialized at the call). %y is only in
  ; the bundle: still virtual, described with field=live %x.
  call void @foo(ptr addrspace(1) %x)
       [ "deopt"(i32 99, i32 99, i64 12, ptr addrspace(1) %y) ]
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; %x's OrigAlloc is retained (PartiallyEscapes — foo's argument).
; CHECK-LABEL: define void @y_refs_x(
; CHECK: %x = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; %y is NeverEscapes — eliminated; only %x's invoke survives.
; CHECK-NOT: invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; The bundle's only reachable virtual object is %y, so its canonical wire ID
; is 0 and its descriptor header is (0<<32)|(4<<16)|12 = 262156. Its field is
; a LIVE oop reference to %x's OrigAlloc (LocalType/T_OBJECT at
; offset 8: (8<<32)|(0<<16)|12 = 34359738380), followed by %x itself.
; CHECK: call void @foo(ptr addrspace(1) %x)
; CHECK-SAME: [ "deopt"(i32 99, i32 99, i64 262156, i64 22222, i32 1,
; CHECK-SAME: i64 34359738380, ptr addrspace(1) %x,
; %y's locals slot becomes a VORefLocalType reference to wire ID 0:
; (0<<32)|(8<<16)|12 = 524300, followed by i32 0.
; CHECK-SAME: i64 524300, i32 0) ]
; CHECK-NOT: poison

!java-method-compilation = !{}
