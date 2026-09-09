; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" \
; RUN:   -jeandle-vm-callback-log=%S/Inputs/453_get_class_after_publish.cblog \
; RUN:   %s | FileCheck %s

; A receiver allocated in this function starts virtual, but publishing it
; materializes it before get_class.  The allocation and publish must remain for
; correctness.  In the PEA-only pipeline, get_class currently remains as well
; because foldGetClass handles virtual receivers; this is a capability-boundary
; check, not a permanent restriction on CFF/type folding.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare hotspotcc ptr addrspace(1) @jeandle.get_class(ptr addrspace(1))
declare void @publish(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define ptr addrspace(1) @test_get_class_after_publish()
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 8 to ptr), i32 16, i1 false)
      to label %body unwind label %unwind
body:
  call void @publish(ptr addrspace(1) %o)
  %c = call hotspotcc ptr addrspace(1)
      @jeandle.get_class(ptr addrspace(1) %o)
  ret ptr addrspace(1) %c
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define ptr addrspace(1) @test_get_class_after_publish
; CHECK: %[[OBJ:[A-Za-z0-9._]+]] = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK: call void @publish(ptr addrspace(1) %[[OBJ]])
; CHECK: call hotspotcc ptr addrspace(1) @jeandle.get_class(ptr addrspace(1) %[[OBJ]])
; CHECK: ret ptr addrspace(1)

!java-method-compilation = !{}
