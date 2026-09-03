; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; VORef across a post-description materialization. At S1,
; %outer is described in the deopt bundle with its field as a VORef to
; %inner (transitive closure describes both). AFTER S1, %inner escapes via
; a DERIVED pointer (%gep) — the generic escape path
; MATERIALIZES %inner at the call instead of marking it ineligible. A
; materialized VO keeps its recorded deopt descriptor (S1's frame state was
; recorded while %inner was still virtual; a deopt there must reconstruct
; it), so %outer's VORef to %inner's canonical wire ID does not dangle:
; S1's bundle
; keeps full descriptors for both objects, %outer's allocation is
; eliminated (its only use is the describing bundle), and %inner's
; allocation stays real with its tracked store replayed onto OrigAlloc
; immediately before the escaping call.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(i32)
declare void @sinkp(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @dangling_voref2(i32 %x) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %inner = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 200 to ptr), i32 16, i1 false)
       to label %n1 unwind label %u
n1:
  %if1 = getelementptr inbounds i8, ptr addrspace(1) %inner, i64 8
  store atomic i32 %x, ptr addrspace(1) %if1 unordered, align 4
  %outer = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 100 to ptr), i32 24, i1 false)
       to label %n2 unwind label %u
n2:
  %of2 = getelementptr inbounds i8, ptr addrspace(1) %outer, i64 16
  store atomic ptr addrspace(1) %inner, ptr addrspace(1) %of2 unordered, align 8
  ; S1: outer root; inner transitive VORef member -> both described.
  call void @sink(i32 %x)
       [ "deopt"(i32 99, i32 99, i64 12, ptr addrspace(1) %outer) ]
  ; AFTER S1: derived-pointer escape of inner -> materialize at the call.
  %gep = getelementptr inbounds i8, ptr addrspace(1) %inner, i64 8
  call void @sinkp(ptr addrspace(1) %gep)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; %inner stays real; %outer's allocation is eliminated and S1's bundle keeps
; the full descriptors of BOTH objects (outer: klass 100 with a VORef field
; to inner; inner: klass 200 with field %x) — no dangling VORef. Canonical
; root-first pool order assigns wire ID 0 to %outer and wire ID 1 to %inner.
; %inner's tracked store is replayed onto OrigAlloc before the escaping
; call; no poison.
; CHECK-LABEL: define void @dangling_voref2(
; CHECK: %inner = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 200 to ptr), i32 16, i1 false)
; CHECK-NOT: new_instance
; CHECK: call void @sink(i32 %x) [ "deopt"(i32 99, i32 99, i64 262156, i64 100, i32 1, i64 68720001036, i32 1, i64 4295229452, i64 200, i32 1, i64 34359738378, i32 %x, i64 524300, i32 0) ]
; CHECK: %pea.matslot = getelementptr inbounds i8, ptr addrspace(1) %inner, i64 8
; CHECK: store atomic i32 %x, ptr addrspace(1) %pea.matslot unordered, align 4
; CHECK: call void @sinkp(ptr addrspace(1) %gep)
; CHECK-NOT: poison

!java-method-compilation = !{}
