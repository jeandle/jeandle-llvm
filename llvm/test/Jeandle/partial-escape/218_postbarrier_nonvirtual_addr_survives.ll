; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; jeandle.post_barrier(addr, oop) where the address operand is a NON-virtual
; array (a function parameter) and the oop operand is a virtual instance.
; foldPostBarrier resolves arg 0 (the address) via resolveVirtualRef; an
; Argument does not bottom out on a virtual object, so it returns nullopt and
; foldPostBarrier returns false — the processJavaOp contract (a non-deleted
; node materializes its virtual operands) drops to the generic escape path:
; materializeAllVirtualOperands materializes the virtual VALUE operand (the
; oop) so the surviving barrier observes a real pointer (never poison), and
; the barrier itself survives guarding the real store. This mirrors
; 406_arraystorecheck_value_leak for the array_store_check analog.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare hotspotcc void @jeandle.post_barrier(ptr addrspace(1), ptr addrspace(1))

declare i32 @__gxx_personality_v0(...)

define void @test_postbarrier_nonvirtual_addr_survives(ptr addrspace(1) %arr) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %v = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 5555 to ptr), i32 16, i1 false)
       to label %n unwind label %u
n:
  %base = getelementptr inbounds i8, ptr addrspace(1) %arr, i32 16
  %p2 = getelementptr inbounds ptr addrspace(1), ptr addrspace(1) %base, i64 2
  store atomic ptr addrspace(1) %v, ptr addrspace(1) %p2 unordered, align 4
  call hotspotcc void @jeandle.post_barrier(ptr addrspace(1) %p2,
                                           ptr addrspace(1) %v)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; The virtual oop must MATERIALIZE (never poison) for the surviving barrier.
; CHECK-LABEL: define void @test_postbarrier_nonvirtual_addr_survives
; CHECK: jeandle.new_instance
; CHECK: store atomic
; CHECK: jeandle.post_barrier

!java-method-compilation = !{}
