; RUN: opt -S -passes="type-check-elimination" -jeandle-vm-callback-log=%S/Inputs/switch-and-frozen-guards.cblog %s 2>&1 | FileCheck %s

; Guards on non-branch terminators and wrapped conditions: switch case values
; pin the traced condition to a pair value, and a frozen condition traces like
; its operand (the check helpers return defined booleans, so the freeze is
; strippable).

declare i1 @jeandle.check_instanceof(ptr addrspace(0), ptr addrspace(1) nonnull)

; switch on zext(check): case 1 = check passed (probe folds true), default =
; check failed (probe folds false).
define i1 @switch_case_values(ptr addrspace(1) %obj) gc "hotspotgc" {
entry:
  %g = call i1 @jeandle.check_instanceof(ptr addrspace(0) inttoptr (i64 3 to ptr addrspace(0)), ptr addrspace(1) nonnull %obj)
  %z = zext i1 %g to i8
  switch i8 %z, label %d [ i8 1, label %t ]
t:
  ; CHECK-LABEL: @switch_case_values(
  ; CHECK: t:
  ; CHECK-NEXT: ret i1 true
  %r = call i1 @jeandle.check_instanceof(ptr addrspace(0) inttoptr (i64 3 to ptr addrspace(0)), ptr addrspace(1) nonnull %obj)
  ret i1 %r
d:
  ; CHECK: d:
  ; CHECK-NEXT: ret i1 false
  %r2 = call i1 @jeandle.check_instanceof(ptr addrspace(0) inttoptr (i64 3 to ptr addrspace(0)), ptr addrspace(1) nonnull %obj)
  ret i1 %r2
}

; A case value outside the traced pair is a dead edge: no fold, no crash.
define i1 @switch_dead_case(ptr addrspace(1) %obj) gc "hotspotgc" {
entry:
  %g = call i1 @jeandle.check_instanceof(ptr addrspace(0) inttoptr (i64 3 to ptr addrspace(0)), ptr addrspace(1) nonnull %obj)
  %z = zext i1 %g to i8
  switch i8 %z, label %d [ i8 7, label %t ]
t:
  ; CHECK-LABEL: @switch_dead_case(
  ; CHECK: t:
  ; CHECK-NEXT: %r = call i1 @jeandle.check_instanceof
  ; CHECK-NEXT: ret i1 %r
  %r = call i1 @jeandle.check_instanceof(ptr addrspace(0) inttoptr (i64 3 to ptr addrspace(0)), ptr addrspace(1) nonnull %obj)
  ret i1 %r
d:
  ; CHECK: d:
  ; CHECK-NEXT: %r2 = call i1 @jeandle.check_instanceof
  ; CHECK-NEXT: ret i1 %r2
  %r2 = call i1 @jeandle.check_instanceof(ptr addrspace(0) inttoptr (i64 3 to ptr addrspace(0)), ptr addrspace(1) nonnull %obj)
  ret i1 %r2
}

; freeze(i1 %check) as the branch condition: same guard as the unfrozen form.
define i1 @frozen_condition(ptr addrspace(1) %obj) gc "hotspotgc" {
entry:
  %g = call i1 @jeandle.check_instanceof(ptr addrspace(0) inttoptr (i64 3 to ptr addrspace(0)), ptr addrspace(1) nonnull %obj)
  %f = freeze i1 %g
  br i1 %f, label %t, label %p
t:
  ret i1 true
p:
  ; CHECK-LABEL: @frozen_condition(
  ; CHECK: p:
  ; CHECK-NEXT: ret i1 false
  %r = call i1 @jeandle.check_instanceof(ptr addrspace(0) inttoptr (i64 3 to ptr addrspace(0)), ptr addrspace(1) nonnull %obj)
  ret i1 %r
}

!java-method-compilation = !{}
