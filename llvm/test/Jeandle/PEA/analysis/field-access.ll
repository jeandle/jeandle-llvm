; RUN: opt -passes='print<pea>' -disable-output %s 2>&1 | FileCheck %s

; Test field access and alias tracking
; Should show AliasInfo with offset

define void @test_field_access(ptr %klass) {
entry:
  ; CHECK: Allocation #1:
  ; CHECK: call ptr addrspace(1) @jeandle.new_instance
  %obj = call ptr addrspace(1) @jeandle.new_instance(ptr %klass, i32 32)

  ; CHECK: store i64 100
  ; CHECK: NoEscape
  %field1 = getelementptr i8, ptr addrspace(1) %obj, i32 0
  store i64 100, ptr addrspace(1) %field1

  ; CHECK: store i64 200
  ; CHECK: NoEscape
  ; CHECK: offset=0=i64 100
  ; CHECK: offset=8=i64 200
  %field2 = getelementptr i8, ptr addrspace(1) %obj, i32 8
  store i64 200, ptr addrspace(1) %field2

  ; CHECK-DAG: %field1 {{.*}}Alloc#1 (offset=0)
  ; CHECK-DAG: %field2 {{.*}}Alloc#1 (offset=8)
  %val = load i64, ptr addrspace(1) %field1

  ret void
}

declare ptr addrspace(1) @jeandle.new_instance(ptr, i32)