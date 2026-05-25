; RUN: opt -passes='print<pea>' -disable-output %s 2>&1 | FileCheck %s

; Test different escape paths
; One path escapes, one doesn't (flow-sensitive)

@global = external global ptr addrspace(1)

define void @test_escape_paths(ptr %klass, i1 %cond) {
entry:
  ; CHECK: Allocation #1:
  ; CHECK: call ptr addrspace(1) @jeandle.new_instance
  %obj = call ptr addrspace(1) @jeandle.new_instance(ptr %klass, i32 16)

  br i1 %cond, label %escape_path, label %no_escape_path

escape_path:
  ; CHECK-DAG: store ptr addrspace(1) %obj, ptr @global{{.*}}: GlobalEscape
  store ptr addrspace(1) %obj, ptr @global
  br label %merge

no_escape_path:
  ; CHECK-DAG: store i64 999, ptr addrspace(1) %gep{{.*}}: NoEscape
  %gep = getelementptr i8, ptr addrspace(1) %obj, i32 0
  store i64 999, ptr addrspace(1) %gep
  br label %merge

merge:
  ; CHECK: Escape points
  ; CHECK: store ptr addrspace(1) %obj, ptr @global
  ; CHECK-NOT: store i64 999
  ret void
}

declare ptr addrspace(1) @jeandle.new_instance(ptr, i32)