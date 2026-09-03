; RUN: opt -S -verify-each \
; RUN:   -passes="require<partial-escape-analysis>,partial-escape-transform" \
; RUN:   -jeandle-vm-callback-log=%S/Inputs/231_value_based_check_value_based.cblog \
; RUN:   %s | FileCheck %s --implicit-check-not=poison

; A surviving call result is an SSA value produced before the later
; safepoint.  The earlier call's own deopt bundle is frame state for that
; earlier safepoint, not a computational dependency of the result.  Walking
; through that historical bundle while auditing %result at @safepoint would
; spuriously reject %o even though both safepoints describe it.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare i32 @produce()
declare void @safepoint()
declare i32 @__gxx_personality_v0(...)

define void @call_result_deopt_bundle_not_dependency()
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 7777 to ptr), i32 16, i1 false)
      to label %body unwind label %unwind

body:
  %result = call i32 @produce()
      [ "deopt"(i32 99, i32 99, i64 12, ptr addrspace(1) %o) ]
  call void @safepoint()
      [ "deopt"(i32 99, i32 99, i64 10, i32 %result,
                  i64 4294967308, ptr addrspace(1) %o) ]
  ret void

unwind:
  %ex = landingpad i64 cleanup
  resume i64 %ex
}

; CHECK-LABEL: define void @call_result_deopt_bundle_not_dependency(
; CHECK-NOT: @jeandle.new_instance
; CHECK: %result = call i32 @produce()
; CHECK: call void @safepoint()

!java-method-compilation = !{}
