; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; jeandle.array_store_check(value, array) where the VALUE is a virtual instance
; and the ARRAY is a non-virtual parameter. foldArrayStoreCheck cannot elide
; (array operand is not a virtual), so by the processJavaOp contract (a
; non-deleted node materializes its virtual operands) it returns false and the generic
; escape path materializes the virtual VALUE operand — the surviving check must
; observe a real pointer, never poison.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare hotspotcc i1 @jeandle.array_store_check(ptr addrspace(1), ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define i1 @test_value_leak_array_nonvirtual(ptr addrspace(1) %arr) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %v = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 5555 to ptr), i32 16, i1 false)
       to label %n unwind label %u
n:
  %r = call hotspotcc i1 @jeandle.array_store_check(ptr addrspace(1) %v,
                                                    ptr addrspace(1) %arr)
  ret i1 %r
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; The virtual value must MATERIALIZE (never poison) — the surviving
; array_store_check observes a real pointer.
; CHECK-LABEL: define i1 @test_value_leak_array_nonvirtual
; CHECK: jeandle.new_instance
; CHECK: jeandle.array_store_check

!java-method-compilation = !{}
