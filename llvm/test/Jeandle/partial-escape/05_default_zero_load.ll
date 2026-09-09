; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; PEA: load from a field that was never stored. The virtual
; object's field starts at the default zero, so PEA replaces the load
; with the i32 zero constant and removes the allocation.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)

declare i32 @__gxx_personality_v0(...)

define i32 @test_default_zero() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %n unwind label %u

n:
  %s = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  %v = load atomic i32, ptr addrspace(1) %s unordered, align 4
  ret i32 %v

u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define i32 @test_default_zero
; CHECK-NOT: jeandle.new_instance
; CHECK: ret i32 0

!java-method-compilation = !{}
