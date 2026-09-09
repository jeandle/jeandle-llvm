; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Malformed multi-scope bundles, graceful bail — both bail exits of the
; scope-boundary finder are covered:
;   1. @multiscope_malformed: the bundle's only adjacent i32 pair is
;      UNEQUAL (i32 5, i32 6 — the duplicated-BCI scope marker is broken),
;      so no equal-i32 pair exists and no scope boundary can be placed.
;   2. @multiscope_malformed_no_i32: the bundle contains NO i32 elements
;      at all (all-i64), so the finder has nothing to match.
; In both cases the analysis-side contract is a graceful bail: no crash,
; the VO is materialized at the call (its OrigAlloc invoke is retained),
; no descriptor is emitted, and no poison is produced.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(i32)
declare i32 @__gxx_personality_v0(...)

define void @multiscope_malformed(i32 %x) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 100 to ptr), i32 16, i1 false)
       to label %n1 unwind label %u
n1:
  %of = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  store atomic i32 %x, ptr addrspace(1) %of unordered, align 4
  ; MALFORMED bundle: the only adjacent i32 pair (i32 5, i32 6) is UNEQUAL
  ; — no scope boundary can be found; %o sits in the (unparseable) locals
  ; area.
  call void @sink(i32 %x)
       [ "deopt"(i32 5, i32 6, i64 12, ptr addrspace(1) %o) ]
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; Graceful bail: the OrigAlloc invoke is retained (%o is materialized), the
; bundle keeps the live %o, and there is no ScalarValueType descriptor
; header (262156), no VORefLocalType slot (524300) and no poison.
; CHECK-LABEL: define void @multiscope_malformed(
; CHECK: invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK: call void @sink(i32 %x) [ "deopt"(i32 5, i32 6, i64 12, ptr addrspace(1) %o) ]
; CHECK-NOT: i64 262156
; CHECK-NOT: i64 524300
; CHECK-NOT: poison

define void @multiscope_malformed_no_i32(i32 %x) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 100 to ptr), i32 16, i1 false)
       to label %n1 unwind label %u
n1:
  %of = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  store atomic i32 %x, ptr addrspace(1) %of unordered, align 4
  ; MALFORMED bundle: ALL-i64 elements — there is no adjacent i32 pair at
  ; all for the scope-boundary finder to match.
  call void @sink(i32 %x)
       [ "deopt"(i64 5, i64 5, i64 12, ptr addrspace(1) %o) ]
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; Same graceful-bail contract: materialized, bundle keeps the live %o, no
; descriptor header (262156), no VORefLocalType slot (524300), no poison.
; CHECK-LABEL: define void @multiscope_malformed_no_i32(
; CHECK: invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK: call void @sink(i32 %x) [ "deopt"(i64 5, i64 5, i64 12, ptr addrspace(1) %o) ]
; CHECK-NOT: i64 262156
; CHECK-NOT: i64 524300
; CHECK-NOT: poison

!java-method-compilation = !{}
