; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Compressed-oops guard: a reference field stored as a
; narrow oop (ptr addrspace(3)) must make getOrCreateFieldIndex bail
; conservatively (-1) instead of asserting (debug) or mis-modeling the slot
; at the wrong width (release). The allocation is kept real and the store
; survives untouched. The module-level gate (PEA skips narrow-oop DataLayout
; modules entirely) is covered by 456_narrow_oop_module_skip.ll; this test
; covers the per-access defense for hand-written / mixed IR.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare i32 @__gxx_personality_v0(...)

define void @narrow_oop_field(ptr addrspace(3) %v) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
         to label %n unwind label %u
n:
  %f = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  store atomic ptr addrspace(3) %v, ptr addrspace(1) %f unordered, align 4
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; The allocation must survive (PEA keeps the object real) and the narrow-oop
; store is left in place.
; CHECK-LABEL: define void @narrow_oop_field(
; CHECK: invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK: store atomic ptr addrspace(3) %v, ptr addrspace(1) %f unordered, align 4
; CHECK: ret void

!java-method-compilation = !{}
