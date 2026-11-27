; RUN: opt -S -verify-each -passes=java-op-length-folding -jeandle-vm-callback-log=%S/../copy-specialization/Inputs/primitive-array-clone.cblog %s | FileCheck %s
; RUN: opt -S -verify-each -passes='java-op-length-folding,java-op-length-folding' -jeandle-vm-callback-log=%S/../copy-specialization/Inputs/primitive-array-clone.cblog %s | FileCheck %s

; Ensure shared-subgraph cache hits preserve allocation collection side effects:
;  - Dead wrapper chains over shared diamonds still allow removing all unused
;    allocations.
;  - Live allocations (with external or deopt uses) are preserved while unused
;    sibling allocations in the same shared diamond are removed.

declare ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32, i1, i1)
declare i32 @jeandle.arraylength(ptr addrspace(1))
declare void @observe(ptr addrspace(1))

; CHECK-LABEL: define i32 @shared_diamond_dead_wrappers(
; CHECK-NOT: @jeandle.new_array
; CHECK-NOT: @jeandle.arraylength
; CHECK: ret i32 %positive
define i32 @shared_diamond_dead_wrappers(i32 %n, i1 %c0, i1 %c1, i1 %c2) {
entry:
  %positive = and i32 %n, 1023
  %a0 = call ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 103 to ptr), i32 %positive, i32 48, i32 16, i32 1000, i1 false, i1 false)
  %a1 = call ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 103 to ptr), i32 %positive, i32 48, i32 16, i32 1000, i1 false, i1 false)
  %s0 = select i1 %c0, ptr addrspace(1) %a0, ptr addrspace(1) %a1
  %fr = freeze ptr addrspace(1) %s0
  %gep = getelementptr i8, ptr addrspace(1) %fr, i64 0
  %s1 = select i1 %c1, ptr addrspace(1) %s0, ptr addrspace(1) %gep
  %s2 = select i1 %c2, ptr addrspace(1) %gep, ptr addrspace(1) %s0
  %root = select i1 %c0, ptr addrspace(1) %s1, ptr addrspace(1) %s2
  %len = call i32 @jeandle.arraylength(ptr addrspace(1) %root)
  ret i32 %len
}

; CHECK-LABEL: define i32 @shared_diamond_one_live_one_dead(
; CHECK: %a0 = call ptr addrspace(1) @jeandle.new_array
; CHECK-NOT: @jeandle.new_array
; CHECK: call void @observe(ptr addrspace(1) %a0)
; CHECK-NOT: @jeandle.arraylength
; CHECK: ret i32 %positive
define i32 @shared_diamond_one_live_one_dead(i32 %n, i1 %c0, i1 %c1, i1 %c2) {
entry:
  %positive = and i32 %n, 1023
  %a0 = call ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 103 to ptr), i32 %positive, i32 48, i32 16, i32 1000, i1 false, i1 false)
  %a1 = call ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 103 to ptr), i32 %positive, i32 48, i32 16, i32 1000, i1 false, i1 false)
  call void @observe(ptr addrspace(1) %a0)
  %s0 = select i1 %c0, ptr addrspace(1) %a0, ptr addrspace(1) %a1
  %s1 = select i1 %c1, ptr addrspace(1) %s0, ptr addrspace(1) %a0
  %s2 = select i1 %c2, ptr addrspace(1) %a1, ptr addrspace(1) %s0
  %root = select i1 %c0, ptr addrspace(1) %s1, ptr addrspace(1) %s2
  %len = call i32 @jeandle.arraylength(ptr addrspace(1) %root)
  ret i32 %len
}

!java-method-compilation = !{}
