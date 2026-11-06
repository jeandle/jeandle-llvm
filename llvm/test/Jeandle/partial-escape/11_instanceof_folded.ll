; RUN: llvm-link -S %s %S/Inputs/phase0_type_checks.ll -o %t
; RUN: opt -S -passes="java-operation-lower<phase=0>" %t -o %t.lowered
; RUN: FileCheck %s --check-prefix=LOWERED < %t.lowered
; RUN: opt -S -passes="instcombine,simplifycfg,loop-simplify,instcombine,partial-escape-iterative" -jeandle-vm-callback-log=%S/Inputs/11_instanceof_folded.cblog %t.lowered | FileCheck %s

; Phase-0 lowering exposes check_instanceof and a zext. PEA folds the
; subtype query on a virtual receiver, then InstCombine produces i32 1.

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

; LOWERED-LABEL: define i32 @test_instanceof
; LOWERED-NOT: call hotspotcc i32 @jeandle.instanceof
; LOWERED: call hotspotcc i1 @jeandle.check_instanceof
; LOWERED: zext i1
; LOWERED-NOT: call hotspotcc i32 @jeandle.instanceof
; LOWERED: ret i32

!java-method-compilation = !{}
