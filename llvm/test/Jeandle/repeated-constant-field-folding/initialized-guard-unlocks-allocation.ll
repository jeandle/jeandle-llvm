; RUN: opt -S -passes="repeated-constant-field-folding" -jeandle-vm-callback-log=%S/Inputs/initialized-guard-unlocks-allocation.cblog %s 2>&1 | FileCheck %s

; Model the Unsafe.allocateInstance shape: an initialization guard contributes
; to the initial slow test passed into the allocation JavaOp. Proving the
; constant Klass initialized must make that contribution false.

declare hotspotcc i1 @jeandle.klass_is_initialized(ptr)
declare ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)

define ptr addrspace(1) @test() #0 gc "hotspotgc" {
entry:
  %initialized = call hotspotcc i1 @jeandle.klass_is_initialized(ptr inttoptr (i64 123456 to ptr))
  %needs.initialization = xor i1 %initialized, true
  %obj = call ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 123456 to ptr), i32 24, i1 %needs.initialization)
  ret ptr addrspace(1) %obj
}

; CHECK-LABEL: define ptr addrspace(1) @test()
; CHECK-NOT:     klass_is_initialized
; CHECK:         %obj = call ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 123456 to ptr), i32 24, i1 false)
; CHECK-NEXT:    ret ptr addrspace(1) %obj

attributes #0 = { "java-method"="1" }

!java-method-compilation = !{}
