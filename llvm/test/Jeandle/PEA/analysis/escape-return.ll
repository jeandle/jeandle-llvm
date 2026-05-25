; RUN: opt -passes='print<pea>' -disable-output %s 2>&1 | FileCheck %s

; Test allocation that escapes via return
; Should show GlobalEscape at return point

define ptr addrspace(1) @test_escape_return(ptr %klass) {
entry:
  ; CHECK: Allocation #1:
  ; CHECK: %obj = call ptr addrspace(1) @jeandle.new_instance
  ; CHECK: NoEscape (creation)
  %obj = call ptr addrspace(1) @jeandle.new_instance(ptr %klass, i32 16)

  ; CHECK: ret ptr
  ; CHECK: GlobalEscape
  ret ptr addrspace(1) %obj
}

declare ptr addrspace(1) @jeandle.new_instance(ptr, i32)