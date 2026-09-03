; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; TODO(resolve-cap-blind-spot): a VO whose address is converted to an integer
; (ptrtoint) and then leaked (stored to a global as an integer, or used to build
; an opaque non-round-trip inttoptr) MUST be materialized: the integer carries
; the VO's address, so the VO cannot be classified NeverEscapes (OrigAlloc RAUW
; to poison would corrupt the leaked integer). This tests whether the opaque
; operand path soundly materializes the VO instead of poisoning it.

@Gi = global i64 0

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare i32 @__gxx_personality_v0(...)

define void @test_resolve_cap_opaque_ptrtoint_escape() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
          ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %cont unwind label %u
cont:
  %s = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  store atomic i32 42, ptr addrspace(1) %s unordered, align 4
  ; Convert the VO pointer to an integer and leak the raw address. The integer
  ; carries %o's address -> %o must be materialized, never poisoned.
  %pi = ptrtoint ptr addrspace(1) %o to i64
  store i64 %pi, ptr @Gi
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @test_resolve_cap_opaque_ptrtoint_escape
; The allocation MUST survive (the leaked integer carries its address):
; CHECK: invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK-NOT: store i64 0, ptr @Gi
; CHECK-NOT: poison

!java-method-compilation = !{}
