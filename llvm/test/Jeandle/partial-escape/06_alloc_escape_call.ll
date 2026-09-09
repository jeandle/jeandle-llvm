; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; PEA negative case: the allocation is passed to an opaque
; function. The oop escapes through the call, so PEA must bail out and
; leave both the allocation and the call intact.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)

declare i32 @__gxx_personality_v0(...)

declare void @sink(ptr addrspace(1))

define void @test_escape_call() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %n unwind label %u

n:
  call void @sink(ptr addrspace(1) %o)
  ret void

u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @test_escape_call
; CHECK: jeandle.new_instance
; CHECK: call void @sink

!java-method-compilation = !{}
