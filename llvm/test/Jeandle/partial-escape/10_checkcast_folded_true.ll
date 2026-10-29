; RUN: llvm-link -S %s %S/Inputs/phase0_type_checks.ll -o %t
; RUN: opt -S -passes="java-operation-lower<phase=0>" %t -o %t.lowered
; RUN: FileCheck %s --check-prefix=LOWERED < %t.lowered
; RUN: opt -S -passes="instcombine,simplifycfg,loop-simplify,instcombine,partial-escape-iterative" -jeandle-vm-callback-log=%S/Inputs/10_checkcast_folded_true.cblog %t.lowered | FileCheck %s

; After phase-0 lowering, check_instanceof on a virtual receiver folds to a constant
; bool when the static subtype relation is known. Here the allocation has
; klass=5 and the cast targets klass=4; IsSubtype(5,4)=true (per cblog) so
; the call is replaced by `i1 true`.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare hotspotcc i1 @jeandle.checkcast(ptr addrspace(0), ptr addrspace(1))

declare i32 @__gxx_personality_v0(...)

define i1 @test_checkcast() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 5 to ptr), i32 16, i1 false)
       to label %n unwind label %u
n:
  %r = call hotspotcc i1 @jeandle.checkcast(
            ptr addrspace(0) inttoptr (i64 4 to ptr),
            ptr addrspace(1) %o)
  ret i1 %r
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define i1 @test_checkcast
; CHECK-NOT: jeandle.new_instance
; CHECK-NOT: jeandle.checkcast
; CHECK: ret i1 true

; LOWERED-LABEL: define i1 @test_checkcast
; LOWERED-NOT: call hotspotcc i1 @jeandle.checkcast
; LOWERED: call hotspotcc i1 @jeandle.check_instanceof
; LOWERED-NOT: call hotspotcc i1 @jeandle.checkcast
; LOWERED: ret i1

!java-method-compilation = !{}
