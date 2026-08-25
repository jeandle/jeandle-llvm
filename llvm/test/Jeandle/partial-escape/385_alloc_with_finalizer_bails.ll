; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" -jeandle-vm-callback-log=%S/Inputs/385_alloc_with_finalizer_bails.cblog %s | FileCheck %s

; HasFinalizer VMCallback. processAllocation refuses to virtualize
; an Instance allocation whose Klass has a finalizer because HotSpot
; must run the original allocation site so InstanceKlass's finalizer
; registration fires; eliding the alloc would skip that registration
; and break finalize() semantics.
;
; Klass 6666 represents a class with a non-trivial finalize() override
; (its cblog returns true for HasFinalizer). Tier1Allocate bails
; immediately, so the original new_instance invoke survives in IR even
; though the allocation is otherwise unobserved. The matching jeandle-
; .check_if_value_based call also stays (no virtual to fold against).

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare hotspotcc i1 @jeandle.check_if_value_based(ptr addrspace(1))

declare i32 @__gxx_personality_v0(...)

define i1 @test_finalizer_bails() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 6666 to ptr), i32 16, i1 false)
       to label %n unwind label %u
n:
  %r = call hotspotcc i1 @jeandle.check_if_value_based(ptr addrspace(1) %o)
  ret i1 %r
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; The new_instance survives because HasFinalizer(6666) returned true and
; processAllocation refused to register a virtual object. The original
; check_if_value_based call also survives (no fold without a virtual).
; CHECK-LABEL: define i1 @test_finalizer_bails
; CHECK: invoke{{.*}}@jeandle.new_instance{{.*}}i64 6666
; CHECK: call{{.*}}@jeandle.check_if_value_based

!java-method-compilation = !{}
