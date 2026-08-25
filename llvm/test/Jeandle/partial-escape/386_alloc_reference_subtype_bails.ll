; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" -jeandle-vm-callback-log=%S/Inputs/386_alloc_reference_subtype_bails.cblog %s | FileCheck %s

; CanVirtualize VMCallback. processAllocation refuses to virtualize
; identity-sensitive Instance allocations (java.lang.ref.Reference and
; java.lang.Thread subtypes). For those classes, the runtime's lifecycle
; tracking (pending-reference list, thread-list registration) keys off
; the actual object identity; eliding the alloc would silently drop that
; registration.
;
; Klass 7777 represents one such class (its cblog returns false for
; CanVirtualize). processAllocation calls HasFinalizer first (returns false,
; not a finalizer-class), then CanVirtualize, sees false, and refuses
; to register a VirtualObject — the original new_instance survives.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare hotspotcc i1 @jeandle.check_if_value_based(ptr addrspace(1))

declare i32 @__gxx_personality_v0(...)

define i1 @test_canvirtualize_bails() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 7777 to ptr), i32 16, i1 false)
       to label %n unwind label %u
n:
  %r = call hotspotcc i1 @jeandle.check_if_value_based(ptr addrspace(1) %o)
  ret i1 %r
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; The new_instance survives because CanVirtualize(7777) returned false.
; CHECK-LABEL: define i1 @test_canvirtualize_bails
; CHECK: invoke{{.*}}@jeandle.new_instance{{.*}}i64 7777
; CHECK: call{{.*}}@jeandle.check_if_value_based

!java-method-compilation = !{}
