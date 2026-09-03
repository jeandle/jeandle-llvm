; RUN: opt -S -verify-each -passes="partial-escape-iterative" \
; RUN:   -jeandle-pea-iterations=3 %s | FileCheck %s

; A compressed-reference replay from an earlier outer round is ordinary input
; to the next analysis round. It must not freeze its allocation in the
; materialized state merely because the canonical replay GEP is named
; pea.matslot.
;
; The first function models a replay whose former escape has disappeared.
; PEA must virtualize the allocation again and eliminate both its physical AS3
; field store and the allocation itself.
;
; The second function models an unchanged replay immediately before a surviving
; escape. PEA must analyze it, but the strict semantic replay matcher must reuse
; the existing AS1->AS3 store instead of deleting and rebuilding it every outer
; round.

target datalayout = "e-p:64:64-p1:64:64-p3:32:32"

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define ptr addrspace(1) @revirtualize_compressed_replay(
    ptr addrspace(1) %ref)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
          ptr inttoptr (i64 75501 to ptr), i32 24, i1 false)
       to label %normal unwind label %unwind
normal:
  %pea.encode.oop = addrspacecast ptr addrspace(1) %ref to ptr addrspace(3)
  %pea.matslot = getelementptr inbounds i8, ptr addrspace(1) %o, i64 16
  store atomic ptr addrspace(3) %pea.encode.oop,
      ptr addrspace(1) %pea.matslot unordered, align 4
  %loaded = load atomic ptr addrspace(3), ptr addrspace(1) %pea.matslot
      unordered, align 4
  %wide = addrspacecast ptr addrspace(3) %loaded to ptr addrspace(1)
  ret ptr addrspace(1) %wide
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

define void @reuse_compressed_replay(ptr addrspace(1) %ref)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
          ptr inttoptr (i64 75502 to ptr), i32 24, i1 false)
       to label %normal unwind label %unwind
normal:
  %pea.encode.oop = addrspacecast ptr addrspace(1) %ref to ptr addrspace(3)
  %pea.matslot = getelementptr inbounds i8, ptr addrspace(1) %o, i64 16
  store atomic ptr addrspace(3) %pea.encode.oop,
      ptr addrspace(1) %pea.matslot unordered, align 4
  call void @sink(ptr addrspace(1) %o)
  ret void
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define ptr addrspace(1) @revirtualize_compressed_replay(
; CHECK-NOT: jeandle.new_instance
; CHECK-NOT: pea.matslot
; CHECK-NOT: addrspacecast
; CHECK-NOT: store
; CHECK-NOT: load
; CHECK: ret ptr addrspace(1) %ref
; CHECK-NEXT: }

; CHECK-LABEL: define void @reuse_compressed_replay(
; CHECK: %o = {{(call|invoke)}} hotspotcc ptr addrspace(1) @jeandle.new_instance(
; CHECK: %pea.encode.oop = addrspacecast ptr addrspace(1) %ref to ptr addrspace(3)
; CHECK-NEXT: %pea.matslot = getelementptr inbounds{{( nuw)?}} i8,
; CHECK-NEXT: store atomic ptr addrspace(3) %pea.encode.oop,
; CHECK-NEXT: call void @sink(ptr addrspace(1) %o)
; CHECK-NOT: pea.matslot
; CHECK-NOT: store atomic ptr addrspace(3)
; CHECK: ret void

!java-method-compilation = !{}
