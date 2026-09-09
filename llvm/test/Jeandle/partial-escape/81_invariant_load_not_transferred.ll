; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; !invariant.load is a memory-LOCATION property ("no write to this location by
; any thread"), not a value property. When PEA forwards a virtual field load
; to its stored value, the stored value may be a load from a DIFFERENT location
; (here a mutable global). Transferring !invariant.load onto that replacement
; would let downstream GVN/LICM assume the global never changes — unsound.
; The replacement load must therefore NOT carry !invariant.load.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare i32 @__gxx_personality_v0(...)

@g = external global i32

define i32 @test_invariant_load_not_transferred() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %n unwind label %u
n:
  ; The stored field value is a load from a mutable global — a different
  ; memory location than the virtual field.
  %gl = load i32, ptr @g
  %s = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  store i32 %gl, ptr addrspace(1) %s
  ; The virtual field read carries !invariant.load.
  %ld = load i32, ptr addrspace(1) %s, !invariant.load !0
  ret i32 %ld
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; %ld forwards to %gl (the global load). %gl must NOT gain !invariant.load.
; CHECK-LABEL: define i32 @test_invariant_load_not_transferred
; CHECK-NOT: invariant.load
; CHECK: ret i32 %gl

!java-method-compilation = !{}
!0 = !{}
