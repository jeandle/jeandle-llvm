; RUN: opt -passes='print<pea>' -disable-output %s 2>&1 | FileCheck %s

; Test loop convergence: allocation before loop with conditional escape inside
; PEA needs to iterate until state converges from NoEscape to GlobalEscape

@global = external global ptr addrspace(1)

define void @test_loop_convergence(ptr %klass, i1 %may_escape) {
entry:
  ; CHECK: Allocation #1:
  ; CHECK: call ptr addrspace(1) @jeandle.new_instance
  ; CHECK: NoEscape (creation)
  %obj = call ptr addrspace(1) @jeandle.new_instance(ptr %klass, i32 16)

  br label %loop

loop:
  br i1 %may_escape, label %escape, label %no_escape

escape:
  store ptr addrspace(1) %obj, ptr @global
  br label %loop_continue

no_escape:
  ; GlobalEscape due to loop convergence
  ; CHECK: store i64 42, ptr addrspace(1) %gep{{.*}}: GlobalEscape
  %gep = getelementptr i8, ptr addrspace(1) %obj, i32 0
  store i64 42, ptr addrspace(1) %gep
  br label %loop_continue

loop_continue:
  br i1 %may_escape, label %loop, label %exit

exit:
  ret void
}

declare ptr addrspace(1) @jeandle.new_instance(ptr, i32)