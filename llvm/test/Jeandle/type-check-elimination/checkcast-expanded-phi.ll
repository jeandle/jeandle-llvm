; RUN: opt -S -passes="type-check-elimination" -jeandle-vm-callback-log=%S/Inputs/checkcast-expanded-phi.cblog %s 2>&1 | FileCheck %s

; A phase-0 checkcast expanded but not dissolved: the branch condition at
; %exit is a boolean phi. The tracer's PHI case skips the constant-true
; incoming from the null path (isNullCheckPath) and traces the non-constant
; incoming to check_instanceof, so the query in %pass folds to true.

declare i1 @jeandle.check_instanceof(ptr addrspace(0), ptr addrspace(1) nonnull)

define i1 @test(ptr addrspace(1) %obj) gc "hotspotgc" {
site:
  %is_null = icmp eq ptr addrspace(1) %obj, null
  br i1 %is_null, label %return_true, label %check_subtype

return_true:
  br label %exit

check_subtype:
  %is_sub = call i1 @jeandle.check_instanceof(ptr addrspace(0) inttoptr (i64 22 to ptr addrspace(0)), ptr addrspace(1) nonnull %obj)
  br label %exit

exit:
  %merged = phi i1 [ true, %return_true ], [ %is_sub, %check_subtype ]
  br i1 %merged, label %pass, label %fail

pass:
  %r = call i1 @jeandle.check_instanceof(ptr addrspace(0) inttoptr (i64 22 to ptr addrspace(0)), ptr addrspace(1) nonnull %obj)
  ret i1 %r

fail:
  ret i1 false
}

; CHECK: check_subtype:
; CHECK-NEXT:   %is_sub = call i1 @jeandle.check_instanceof
; CHECK: pass:
; CHECK-NEXT:   ret i1 true

!java-method-compilation = !{}
