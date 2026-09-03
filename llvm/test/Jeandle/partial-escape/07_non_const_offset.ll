; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; PEA negative case: the GEP uses a runtime-variable index, so
; PEA cannot map the access to a constant field offset. The allocation,
; store, and load must all be preserved.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)

declare i32 @__gxx_personality_v0(...)

define i32 @test_var_offset(i64 %idx, i32 %val) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 64, i1 false)
       to label %n unwind label %u

n:
  %s = getelementptr inbounds i8, ptr addrspace(1) %o, i64 %idx
  store atomic i32 %val, ptr addrspace(1) %s unordered, align 4
  %v = load atomic i32, ptr addrspace(1) %s unordered, align 4
  ret i32 %v

u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define i32 @test_var_offset
; CHECK: jeandle.new_instance
; CHECK: store atomic
; CHECK: load atomic

!java-method-compilation = !{}
