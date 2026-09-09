; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Lit coverage for the Case-A fallback on a phi with a virtual incoming
; on one arm and a null pointer on the other. The merge-time AliasMap
; consultation marks the virtual-incoming side eligible for per-pred
; materialization; the null side is treated as a non-virtual pointer.
; Materialization retains OrigAlloc on the virtual arm and the PHI survives
; with %o / null incomings.
;
; This is purely a regression guard — today's processBlockPhis Case-A
; fallback at PartialEscapeAnalysis.cpp already handles the pattern; we
; assert the end-to-end behaviour stays sound.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @test_phi_virt_null(i1 %c)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  br i1 %c, label %alloc, label %nullarm
alloc:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %merge unwind label %u
nullarm:
  br label %merge
merge:
  %x = phi ptr addrspace(1) [ %o, %alloc ], [ null, %nullarm ]
  call void @sink(ptr addrspace(1) %x)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; OrigAlloc is the only allocation; the null arm is unchanged.
; CHECK-LABEL: define void @test_phi_virt_null
; CHECK: %o = invoke{{.*}}@jeandle.new_instance
; CHECK-NOT: @jeandle.new_instance
; CHECK: %x = phi ptr addrspace(1) [ %o, %alloc ], [ null, %nullarm ]
; CHECK: call void @sink(ptr addrspace(1) %x)

!java-method-compilation = !{}
