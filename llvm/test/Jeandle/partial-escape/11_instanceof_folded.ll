; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" -jeandle-vm-callback-log=%S/Inputs/11_instanceof_folded.cblog %s | FileCheck %s

; PEA: jeandle.instanceof on a virtual (non-null) receiver folds to
; i32 1 when the subtype relation is statically known.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare hotspotcc i32 @jeandle.instanceof(ptr addrspace(0), ptr addrspace(1))

declare i32 @__gxx_personality_v0(...)

define i32 @test_instanceof() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 5 to ptr), i32 16, i1 false)
       to label %n unwind label %u
n:
  %r = call hotspotcc i32 @jeandle.instanceof(
            ptr addrspace(0) inttoptr (i64 4 to ptr),
            ptr addrspace(1) %o)
  ret i32 %r
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define i32 @test_instanceof
; CHECK-NOT: jeandle.new_instance
; CHECK-NOT: jeandle.instanceof
; CHECK: ret i32 1

!java-method-compilation = !{}
