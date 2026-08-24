; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" \
; RUN:   %s | FileCheck %s

; The third new_instance operand is not merely a performance hint. When true,
; the allocation must enter the runtime, which may initialize the class or
; reject an interface/abstract Klass with InstantiationException. PEA may
; virtualize only when this operand is proven false.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare i32 @__gxx_personality_v0(...)

define void @constant_false_is_virtualizable()
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 45401 to ptr), i32 16, i1 false)
      to label %normal unwind label %unwind
normal:
  ret void
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @constant_false_is_virtualizable
; CHECK-NOT: jeandle.new_instance
; CHECK: ret void

define void @constant_true_keeps_runtime_semantics()
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 45402 to ptr), i32 16, i1 true)
      to label %normal unwind label %unwind
normal:
  ret void
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @constant_true_keeps_runtime_semantics
; CHECK: invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
; CHECK-SAME: ptr inttoptr (i64 45402 to ptr), i32 16, i1 true)
; CHECK: to label %normal unwind label %unwind

define void @dynamic_test_keeps_runtime_semantics(i1 %initial_slow_test)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 45403 to ptr), i32 16, i1 %initial_slow_test)
      to label %normal unwind label %unwind
normal:
  ret void
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @dynamic_test_keeps_runtime_semantics
; CHECK: invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
; CHECK-SAME: ptr inttoptr (i64 45403 to ptr), i32 16, i1 %initial_slow_test)
; CHECK: to label %normal unwind label %unwind

!java-method-compilation = !{}
