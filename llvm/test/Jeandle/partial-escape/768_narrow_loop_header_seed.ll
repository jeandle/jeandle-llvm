; RUN: opt -S -verify-each -passes="partial-escape-iterative" \
; RUN:   -jeandle-pea-iterations=1 %s | FileCheck %s

; The first seeded loop-body pass must register a compressed AS3 loop-header
; PHI as the same whole-object alias as its preheader incoming. Otherwise the
; body load is missed in round one and elimination depends on a later outer
; canonicalization round converting the representation back to AS1.

target datalayout = "e-p:64:64-p1:64:64-p3:32:32"

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare i32 @__gxx_personality_v0(...)

define i32 @narrow_loop_header_seed(i1 %again, i32 %value)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
           ptr inttoptr (i64 76801 to ptr), i32 16, i1 false)
       to label %init unwind label %unwind

init:
  %slot = getelementptr inbounds i8, ptr addrspace(1) %o, i64 12
  store atomic i32 %value, ptr addrspace(1) %slot unordered, align 4
  %narrow = addrspacecast ptr addrspace(1) %o to ptr addrspace(3)
  br label %header

header:
  %carry = phi ptr addrspace(3) [ %narrow, %init ], [ %carry, %latch ]
  %wide = addrspacecast ptr addrspace(3) %carry to ptr addrspace(1)
  %body.slot = getelementptr inbounds i8, ptr addrspace(1) %wide, i64 12
  %loaded = load atomic i32, ptr addrspace(1) %body.slot unordered, align 4
  br i1 %again, label %latch, label %exit

latch:
  br label %header

exit:
  ret i32 %loaded

unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define i32 @narrow_loop_header_seed(
; CHECK-NOT: @jeandle.new_instance
; CHECK-NOT: store atomic
; CHECK-NOT: load atomic
; CHECK: ret i32 %value

!java-method-compilation = !{}
