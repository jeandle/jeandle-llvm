; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" -jeandle-vm-callback-log=%S/Inputs/214_postbarrier_virtual_array_fold.cblog %s | FileCheck %s

; Object[] virtual array (klass 8888) holding a virtual instance (klass 5555).
; The Jeandle frontend emits jeandle.post_barrier(addr, oop) after every
; T_OBJECT array store (jeandleAbstractInterpreter.cpp:do_array_store_inner).
; Before the post_barrier fold, processJavaOp had no case for it, so the
; barrier call used the virtual array and forced its materialization —
; defeating PEA for `new Object[]{...}`. foldPostBarrier resolves the address
; operand to the virtual array and erases the barrier (emitReplaceCall with a
; null replacement, the void-JavaOp deletion form). The store is eliminated and
; recorded into the array's field state, and the stored oop is recorded as a
; nested virtual reference, so neither the array nor the oop ever materializes:
; the allocations, the store, and the barrier all disappear.

@arrayOopDesc.element_size.object = private constant i32 8

declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32)
declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare hotspotcc void @jeandle.post_barrier(ptr addrspace(1), ptr addrspace(1))

declare i32 @__gxx_personality_v0(...)

define i32 @test_postbarrier_virtual_array_fold() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %arr = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
            ptr inttoptr (i64 8888 to ptr), i32 4, i32 48, i32 16, i32 1048576)
         to label %n1 unwind label %u
n1:
  %v = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 5555 to ptr), i32 16, i1 false)
       to label %n2 unwind label %u
n2:
  %base = getelementptr inbounds i8, ptr addrspace(1) %arr, i32 16
  %p2 = getelementptr inbounds ptr addrspace(1), ptr addrspace(1) %base, i64 2
  store atomic ptr addrspace(1) %v, ptr addrspace(1) %p2 unordered, align 8
  call hotspotcc void @jeandle.post_barrier(ptr addrspace(1) %p2,
                                           ptr addrspace(1) %v)
  ret i32 0
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define i32 @test_postbarrier_virtual_array_fold
; CHECK-NOT: jeandle.new_array
; CHECK-NOT: jeandle.new_instance
; CHECK-NOT: store
; CHECK-NOT: jeandle.post_barrier
; CHECK: ret i32 0

!java-method-compilation = !{}
