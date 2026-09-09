; RUN: opt -S -passes="type-check-elimination" -jeandle-vm-callback-log=%S/Inputs/instanceof-phi-duplicate-edge.cblog %s 2>&1 | FileCheck %s

; Negative guard: the branch to the PHI's block is a duplicate edge (both
; successors are the merge), so neither outcome can be attributed to the edge
; and NO sharpening may happen. If a duplicate edge wrongly sharpened %a to 22,
; the instanceof on %phi would fold.

declare i1 @jeandle.check_instanceof(ptr addrspace(0), ptr addrspace(1) nonnull)

define i1 @test(ptr addrspace(1) "java-klass"="5" %a) #0 gc "hotspotgc" {
entry:
  %c = call i1 @jeandle.check_instanceof(ptr addrspace(0) inttoptr (i64 22 to ptr addrspace(0)), ptr addrspace(1) nonnull %a)
  br i1 %c, label %merge, label %merge

merge:
  %phi = phi ptr addrspace(1) [ %a, %entry ], [ %a, %entry ]
  %r = call i1 @jeandle.check_instanceof(ptr addrspace(0) inttoptr (i64 22 to ptr addrspace(0)), ptr addrspace(1) nonnull %phi)
  ret i1 %r
}

; The query on %phi must be preserved (no sharpening from the duplicate edge).
; CHECK: %r = call i1 @jeandle.check_instanceof
; CHECK: ret i1 %r

attributes #0 = { "java-method"="0" }

!java-method-compilation = !{}
