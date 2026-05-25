; RUN: opt -passes='print<pea>' -disable-output %s 2>&1 | FileCheck %s

; Test basic allocation that doesn't escape
; Should show NoEscape throughout

define void @test_basic_alloc(ptr %klass) {
entry:
  ; CHECK: Allocation #1:
  ; CHECK: %obj = call ptr addrspace(1) @jeandle.new_instance
  ; CHECK: NoEscape (creation)
  %obj = call ptr addrspace(1) @jeandle.new_instance(ptr %klass, i32 16)

  ; CHECK: store i64 42
  ; CHECK: NoEscape
  %gep = getelementptr i8, ptr addrspace(1) %obj, i32 0
  store i64 42, ptr addrspace(1) %gep

  ; CHECK: ret void
  ; CHECK: NoEscape
  ret void
}

declare ptr addrspace(1) @jeandle.new_instance(ptr, i32)