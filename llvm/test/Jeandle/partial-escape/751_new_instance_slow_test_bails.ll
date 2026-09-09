; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; The third new_instance operand selects the runtime slow path. PEA only
; virtualizes the exact fast-path form (i1 false): it does not model class
; initialization, instantiation checks, or their exceptional side effects.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare i32 @__gxx_personality_v0(...)
declare void @sink(ptr addrspace(1))

define i32 @test_fast_path_is_virtualized() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %obj = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 75101 to ptr), i32 16, i1 false)
      to label %normal unwind label %unwind
normal:
  %slot = getelementptr inbounds i8, ptr addrspace(1) %obj, i64 8
  store atomic i32 42, ptr addrspace(1) %slot unordered, align 4
  %value = load atomic i32, ptr addrspace(1) %slot unordered, align 4
  ret i32 %value
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

define void @test_true_slow_path_is_retained() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %obj = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 75102 to ptr), i32 16, i1 true)
      to label %normal unwind label %unwind
normal:
  call void @sink(ptr addrspace(1) %obj)
  ret void
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

define void @test_unknown_slow_path_is_retained(i1 %slow) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %obj = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 75103 to ptr), i32 16, i1 %slow)
      to label %normal unwind label %unwind
normal:
  call void @sink(ptr addrspace(1) %obj)
  ret void
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define i32 @test_fast_path_is_virtualized(
; CHECK-NOT: jeandle.new_instance
; CHECK: ret i32 42

; CHECK-LABEL: define void @test_true_slow_path_is_retained(
; CHECK: invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
; CHECK-SAME: ptr inttoptr (i64 75102 to ptr), i32 16, i1 true)

; CHECK-LABEL: define void @test_unknown_slow_path_is_retained(
; CHECK: invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
; CHECK-SAME: ptr inttoptr (i64 75103 to ptr), i32 16, i1 %slow)

!java-method-compilation = !{}
