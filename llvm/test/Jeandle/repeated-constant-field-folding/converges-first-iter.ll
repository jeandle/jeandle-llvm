; RUN: opt -S -passes="repeated-constant-field-folding" -jeandle-vm-callback-log=%S/Inputs/converges-first-iter.cblog %s 2>&1 | FileCheck %s

; Sanity check: when CFF folds everything reachable in one pass and the
; cleanup exposes no new opportunity, the wrapper must converge after a
; single round (CFF returns PreservedAnalyses::all() on its second call)
; and must not regress simple folds.

@oop_handle_Test_0 = external global ptr addrspace(1)

define i32 @test() gc "hotspotgc" {
entry:
  %base = load ptr addrspace(1), ptr @oop_handle_Test_0
  %addr = getelementptr i8, ptr addrspace(1) %base, i64 12
  %value = load i32, ptr addrspace(1) %addr
  ret i32 %value
}

; CHECK: ret i32 42

!java-method-compilation = !{}
