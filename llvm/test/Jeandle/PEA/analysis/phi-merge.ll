; RUN: opt -passes='print<pea>' -disable-output %s 2>&1 | FileCheck %s

; Test PHI merge with different compatible allocations
; Creates VirtualAllocationObject for PHI, both allocations remain NoEscape

define void @test_phi_merge(ptr %klass, i1 %cond) {
entry:
  %obj1 = call ptr addrspace(1) @jeandle.new_instance(ptr %klass, i32 16)
  %gep1 = getelementptr i8, ptr addrspace(1) %obj1, i32 0
  store i64 42, ptr addrspace(1) %gep1

  br i1 %cond, label %bb1, label %merge

bb1:
  %obj2 = call ptr addrspace(1) @jeandle.new_instance(ptr %klass, i32 16)
  %gep2 = getelementptr i8, ptr addrspace(1) %obj2, i32 0
  store i64 100, ptr addrspace(1) %gep2
  br label %merge

merge:
  %phi = phi ptr addrspace(1) [%obj1, %entry], [%obj2, %bb1]
  %phi_gep = getelementptr i8, ptr addrspace(1) %phi, i32 0
  %val = load i64, ptr addrspace(1) %phi_gep
  ; CHECK: Allocation #3:
  ; CHECK: Virtual allocation (PHI merged)
  ; CHECK: %phi = phi ptr addrspace(1) [ %obj1, %entry ], [ %obj2, %bb1 ]
  ; CHECK: NoEscape (creation)
  ; CHECK-DAG: %phi {{.*}}Alloc#3
  ; CHECK-DAG: %phi_gep {{.*}}Alloc#3 (offset=0)
  ret void
}

declare ptr addrspace(1) @jeandle.new_instance(ptr, i32)