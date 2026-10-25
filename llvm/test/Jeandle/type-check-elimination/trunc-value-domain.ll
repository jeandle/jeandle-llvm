; RUN: opt -S -passes="type-check-elimination" -jeandle-vm-callback-log=%S/Inputs/trunc-value-domain.cblog %s 2>&1 | FileCheck %s

; Integer casts map the traced value pair to the cast's result width. zext and
; sext are injective, but trunc can collapse a distinct pair when both values
; agree below the target width: the truncated condition is then constant with
; respect to the check outcome, so no branch or switch edge may publish the
; check's type facts. Hierarchy: 1=Object 2=Animal 3=Dog.

declare i1 @jeandle.check_instanceof(ptr addrspace(0), ptr addrspace(1) nonnull)

; select {0,2} trunc i8 -> i1 collapses to {0,0}: the branch is constant false
; regardless of the check, so the always-taken no edge carries no exclusion and
; the probe must stay live.
define i1 @trunc_collapsed_pair(ptr addrspace(1) %obj) gc "hotspotgc" {
entry:
  %g = call i1 @jeandle.check_instanceof(ptr addrspace(0) inttoptr (i64 3 to ptr addrspace(0)), ptr addrspace(1) nonnull %obj)
  %mapped = select i1 %g, i8 2, i8 0
  %truncated = trunc i8 %mapped to i1
  br i1 %truncated, label %yes, label %no
yes:
  ret i1 false
no:
  %r = call i1 @jeandle.check_instanceof(ptr addrspace(0) inttoptr (i64 3 to ptr addrspace(0)), ptr addrspace(1) nonnull %obj)
  ret i1 %r
}

; select {1,3} trunc i8 -> i1 collapses to {1,1}: the branch is constant true,
; so the always-taken yes edge carries no exclusion and the probe must stay
; live.
define i1 @trunc_collapsed_pair_one(ptr addrspace(1) %obj) gc "hotspotgc" {
entry:
  %g = call i1 @jeandle.check_instanceof(ptr addrspace(0) inttoptr (i64 3 to ptr addrspace(0)), ptr addrspace(1) nonnull %obj)
  %mapped = select i1 %g, i8 3, i8 1
  %truncated = trunc i8 %mapped to i1
  br i1 %truncated, label %yes, label %no
no:
  ret i1 false
yes:
  %r = call i1 @jeandle.check_instanceof(ptr addrspace(0) inttoptr (i64 3 to ptr addrspace(0)), ptr addrspace(1) nonnull %obj)
  ret i1 %r
}

; Same collapse from a wider source: i16 {0,2} trunc i16 -> i1 is {0,0}. The
; no edge must stay fact-free.
define i1 @trunc_wide_collapsed(ptr addrspace(1) %obj) gc "hotspotgc" {
entry:
  %g = call i1 @jeandle.check_instanceof(ptr addrspace(0) inttoptr (i64 3 to ptr addrspace(0)), ptr addrspace(1) nonnull %obj)
  %mapped = select i1 %g, i16 2, i16 0
  %truncated = trunc i16 %mapped to i1
  br i1 %truncated, label %yes, label %no
yes:
  ret i1 false
no:
  %r = call i1 @jeandle.check_instanceof(ptr addrspace(0) inttoptr (i64 3 to ptr addrspace(0)), ptr addrspace(1) nonnull %obj)
  ret i1 %r
}

; i16 {1,257} trunc i16 -> i8 collapses to {1,1}: the switch is constant 1, so
; the case edge must not inherit the passed side's klass fact and the probe
; must stay live.
define i1 @trunc_switch_collapsed(ptr addrspace(1) %obj) gc "hotspotgc" {
entry:
  %g = call i1 @jeandle.check_instanceof(ptr addrspace(0) inttoptr (i64 3 to ptr addrspace(0)), ptr addrspace(1) nonnull %obj)
  %mapped = select i1 %g, i16 257, i16 1
  %truncated = trunc i16 %mapped to i8
  switch i8 %truncated, label %def [ i8 1, label %one ]
def:
  ret i1 false
one:
  %r = call i1 @jeandle.check_instanceof(ptr addrspace(0) inttoptr (i64 3 to ptr addrspace(0)), ptr addrspace(1) nonnull %obj)
  ret i1 %r
}

; Control: select {0,1} trunc i8 -> i1 keeps a discriminating {0,1} pair, so
; the yes edge still proves the check passed and the probe folds.
define i1 @trunc_discriminating(ptr addrspace(1) %obj) gc "hotspotgc" {
entry:
  %g = call i1 @jeandle.check_instanceof(ptr addrspace(0) inttoptr (i64 3 to ptr addrspace(0)), ptr addrspace(1) nonnull %obj)
  %mapped = select i1 %g, i8 1, i8 0
  %truncated = trunc i8 %mapped to i1
  br i1 %truncated, label %yes, label %no
yes:
  %r = call i1 @jeandle.check_instanceof(ptr addrspace(0) inttoptr (i64 3 to ptr addrspace(0)), ptr addrspace(1) nonnull %obj)
  ret i1 %r
no:
  ret i1 false
}

; CHECK-LABEL: @trunc_collapsed_pair(
; CHECK: no:
; CHECK-NEXT: %r = call i1 @jeandle.check_instanceof
; CHECK-NEXT: ret i1 %r
; CHECK-LABEL: @trunc_collapsed_pair_one(
; CHECK: yes:
; CHECK-NEXT: %r = call i1 @jeandle.check_instanceof
; CHECK-NEXT: ret i1 %r
; CHECK-LABEL: @trunc_wide_collapsed(
; CHECK: no:
; CHECK-NEXT: %r = call i1 @jeandle.check_instanceof
; CHECK-NEXT: ret i1 %r
; CHECK-LABEL: @trunc_switch_collapsed(
; CHECK: one:
; CHECK-NEXT: %r = call i1 @jeandle.check_instanceof
; CHECK-NEXT: ret i1 %r
; CHECK-LABEL: @trunc_discriminating(
; CHECK: yes:
; CHECK-NEXT: ret i1 true

!java-method-compilation = !{}
