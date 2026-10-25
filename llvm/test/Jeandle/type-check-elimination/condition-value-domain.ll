; RUN: opt -S -passes="type-check-elimination" -jeandle-vm-callback-log=%S/Inputs/condition-value-domain.cblog %s 2>&1 | FileCheck %s

; Widened boolean conditions are tracked by their exact value domain, never by
; an assumed {0,1}. A widened check result merged with a constant that belongs
; to neither domain value makes the condition check-independent: the live
; probe on the "no check executed" edge must NOT fold. Hierarchy:
; 1=Object 2=Animal 3=Dog 4=Cat 5=Woof(iface).

declare i1 @jeandle.check_instanceof(ptr addrspace(0), ptr addrspace(1) nonnull)

; A NOT-form guard around a check must keep its constraint polarity: the
; xor-true edge is the CHECK-FAILED edge (exclusion only), so the phi of
; [obj(null), obj(not-Dog), exact Cat] must NOT prove instanceof Animal.
; An inverted value pairing here would put {Klass: Dog} on the not-Dog edge,
; join to LCA(Dog, Cat) = Animal, and miscompile the probe to true.
define i1 @xor_guard_polarity(ptr addrspace(1) %obj, ptr addrspace(1) "java-klass"="4" "java-klass-exact" %cat) gc "hotspotgc" {
entry:
  %is_null = icmp eq ptr addrspace(1) %obj, null
  br i1 %is_null, label %merge, label %check_dog
check_dog:
  %g = call i1 @jeandle.check_instanceof(ptr addrspace(0) inttoptr (i64 3 to ptr addrspace(0)), ptr addrspace(1) nonnull %obj)
  %not_dog = xor i1 %g, true
  br i1 %not_dog, label %merge, label %catarm
catarm:
  br label %merge
merge:
  %x = phi ptr addrspace(1) [ %obj, %entry ], [ %obj, %check_dog ], [ %cat, %catarm ]
  ; CHECK-LABEL: @xor_guard_polarity(
  ; CHECK: %x = phi ptr addrspace(1)
  ; CHECK-NEXT: %r = call i1 @jeandle.check_instanceof
  ; CHECK-NEXT: ret i1 %r
  %r = call i1 @jeandle.check_instanceof(ptr addrspace(0) inttoptr (i64 2 to ptr addrspace(0)), ptr addrspace(1) nonnull %x)
  ret i1 %r
}


; phi i8 [zext(check Dog), pb], [2, qb] + `icmp eq i8 %p, 1`. p==2 (qb arm)
; reaches the f edge with obj possibly a Dog: the probe must stay live.
define i1 @phi_const2_eq1(ptr addrspace(1) %obj, i1 %s) gc "hotspotgc" {
entry:
  %g = call i1 @jeandle.check_instanceof(ptr addrspace(0) inttoptr (i64 3 to ptr addrspace(0)), ptr addrspace(1) nonnull %obj)
  %z = zext i1 %g to i8
  br i1 %s, label %pb, label %qb
pb:
  br label %m
qb:
  br label %m
m:
  %p = phi i8 [ %z, %pb ], [ 2, %qb ]
  %c = icmp eq i8 %p, 1
  br i1 %c, label %t, label %f
t:
  ret i1 true
f:
  %r = call i1 @jeandle.check_instanceof(ptr addrspace(0) inttoptr (i64 3 to ptr addrspace(0)), ptr addrspace(1) nonnull %obj)
  ret i1 %r
}

; Same with `icmp ne i8 %p, 1`; the probe now sits on the p in {0,2} edge.
define i1 @phi_const2_ne1(ptr addrspace(1) %obj, i1 %s) gc "hotspotgc" {
entry:
  %g = call i1 @jeandle.check_instanceof(ptr addrspace(0) inttoptr (i64 3 to ptr addrspace(0)), ptr addrspace(1) nonnull %obj)
  %z = zext i1 %g to i8
  br i1 %s, label %pb, label %qb
pb:
  br label %m
qb:
  br label %m
m:
  %p = phi i8 [ %z, %pb ], [ 2, %qb ]
  %c = icmp ne i8 %p, 1
  br i1 %c, label %t, label %f
t:
  %r = call i1 @jeandle.check_instanceof(ptr addrspace(0) inttoptr (i64 3 to ptr addrspace(0)), ptr addrspace(1) nonnull %obj)
  ret i1 %r
f:
  ret i1 false
}

; select i1 %w, i8 %z, i8 2 + `icmp eq i8 %s, 1`. sel==2 (w false) carries no
; check: the probe on the f edge must stay live.
define i1 @sel_const2_eq1(ptr addrspace(1) %obj, i1 %w) gc "hotspotgc" {
entry:
  %g = call i1 @jeandle.check_instanceof(ptr addrspace(0) inttoptr (i64 3 to ptr addrspace(0)), ptr addrspace(1) nonnull %obj)
  %z = zext i1 %g to i8
  %s = select i1 %w, i8 %z, i8 2
  %c = icmp eq i8 %s, 1
  br i1 %c, label %t, label %f
t:
  ret i1 true
f:
  %r = call i1 @jeandle.check_instanceof(ptr addrspace(0) inttoptr (i64 3 to ptr addrspace(0)), ptr addrspace(1) nonnull %obj)
  ret i1 %r
}

; or i8 of two traced values where one operand can exceed {0,1}: the f edge
; carries o in {0,2,3}; o==2 means the Cat check never ran. The Cat probe on
; the f edge must stay live.
define i1 @or_sel_const2_eq1(ptr addrspace(1) %obj, i1 %w) gc "hotspotgc" {
entry:
  %g1 = call i1 @jeandle.check_instanceof(ptr addrspace(0) inttoptr (i64 3 to ptr addrspace(0)), ptr addrspace(1) nonnull %obj)
  %g2 = call i1 @jeandle.check_instanceof(ptr addrspace(0) inttoptr (i64 4 to ptr addrspace(0)), ptr addrspace(1) nonnull %obj)
  %z2 = zext i1 %g2 to i8
  %sel = select i1 %w, i8 %z2, i8 2
  %o = or i8 %z2, %sel
  %c = icmp eq i8 %o, 1
  br i1 %c, label %t, label %f
t:
  ret i1 true
f:
  %r = call i1 @jeandle.check_instanceof(ptr addrspace(0) inttoptr (i64 4 to ptr addrspace(0)), ptr addrspace(1) nonnull %obj)
  ret i1 %r
}

; sext i1 -> i8 has domain {0,-1}: `sle %s, 0` is always true, so the t edge
; carries no check outcome. The probe must stay live on both edges.
define i1 @sext_sle0(ptr addrspace(1) %obj) gc "hotspotgc" {
entry:
  %g = call i1 @jeandle.check_instanceof(ptr addrspace(0) inttoptr (i64 3 to ptr addrspace(0)), ptr addrspace(1) nonnull %obj)
  %s = sext i1 %g to i8
  %c = icmp sle i8 %s, 0
  br i1 %c, label %t, label %f
t:
  %r = call i1 @jeandle.check_instanceof(ptr addrspace(0) inttoptr (i64 3 to ptr addrspace(0)), ptr addrspace(1) nonnull %obj)
  ret i1 %r
f:
  ret i1 false
}

; `ne %s, 0` IS discriminating on {0,-1} (true only for -1, i.e. passed):
; the t edge proves the check passed, the f edge proves it failed.
define i1 @sext_ne0(ptr addrspace(1) %obj) gc "hotspotgc" {
entry:
  %g = call i1 @jeandle.check_instanceof(ptr addrspace(0) inttoptr (i64 3 to ptr addrspace(0)), ptr addrspace(1) nonnull %obj)
  %s = sext i1 %g to i8
  %c = icmp ne i8 %s, 0
  br i1 %c, label %t, label %f
t:
  ret i1 true
f:
  %r = call i1 @jeandle.check_instanceof(ptr addrspace(0) inttoptr (i64 3 to ptr addrspace(0)), ptr addrspace(1) nonnull %obj)
  ret i1 %r
}

; A bitwise op with a constant is a deterministic function of the traced
; operand, so the domain pair maps through it exactly: `xor i8 %z, 1` keeps
; inverting (t edge = failed -> Dog probe folds false; f edge = passed -> the
; non-Dog guard folds true).
define i1 @xor_i8_const(ptr addrspace(1) %obj) gc "hotspotgc" {
entry:
  %g = call i1 @jeandle.check_instanceof(ptr addrspace(0) inttoptr (i64 3 to ptr addrspace(0)), ptr addrspace(1) nonnull %obj)
  %z = zext i1 %g to i8
  %x = xor i8 %z, 1
  %c = icmp ne i8 %x, 0
  br i1 %c, label %t, label %f
t:
  %r = call i1 @jeandle.check_instanceof(ptr addrspace(0) inttoptr (i64 3 to ptr addrspace(0)), ptr addrspace(1) nonnull %obj)
  ret i1 %r
f:
  %r2 = call i1 @jeandle.check_instanceof(ptr addrspace(0) inttoptr (i64 2 to ptr addrspace(0)), ptr addrspace(1) nonnull %obj)
  ret i1 %r2
}

; `or i8 %z, 2` has domain {2,3}: `ne 0` is always true, so neither edge
; carries a check outcome and both probes must stay live.
define i1 @or_i8_const2(ptr addrspace(1) %obj) gc "hotspotgc" {
entry:
  %g = call i1 @jeandle.check_instanceof(ptr addrspace(0) inttoptr (i64 3 to ptr addrspace(0)), ptr addrspace(1) nonnull %obj)
  %z = zext i1 %g to i8
  %o = or i8 %z, 2
  %c = icmp ne i8 %o, 0
  br i1 %c, label %t, label %f
t:
  %r = call i1 @jeandle.check_instanceof(ptr addrspace(0) inttoptr (i64 3 to ptr addrspace(0)), ptr addrspace(1) nonnull %obj)
  ret i1 %r
f:
  %r2 = call i1 @jeandle.check_instanceof(ptr addrspace(0) inttoptr (i64 3 to ptr addrspace(0)), ptr addrspace(1) nonnull %obj)
  ret i1 %r2
}

; `sub C, %traced` is likewise a deterministic function of the traced operand
; and maps the pair through (`sub i1 0, %check` is its own canonical form
; before InstCombine turns it into an xor).
define i1 @sub_const_not(ptr addrspace(1) %obj) gc "hotspotgc" {
entry:
  %g = call i1 @jeandle.check_instanceof(ptr addrspace(0) inttoptr (i64 3 to ptr addrspace(0)), ptr addrspace(1) nonnull %obj)
  %n = sub i1 0, %g
  br i1 %n, label %t, label %f
t:
  ret i1 true
f:
  %r = call i1 @jeandle.check_instanceof(ptr addrspace(0) inttoptr (i64 3 to ptr addrspace(0)), ptr addrspace(1) nonnull %obj)
  ret i1 %r
}

; CHECK-LABEL: @phi_const2_eq1(
; CHECK: f:
; CHECK-NEXT: %r = call i1 @jeandle.check_instanceof
; CHECK-NEXT: ret i1 %r
; CHECK-LABEL: @phi_const2_ne1(
; CHECK: t:
; CHECK-NEXT: %r = call i1 @jeandle.check_instanceof
; CHECK-NEXT: ret i1 %r
; CHECK-LABEL: @sel_const2_eq1(
; CHECK: f:
; CHECK-NEXT: %r = call i1 @jeandle.check_instanceof
; CHECK-NEXT: ret i1 %r
; CHECK-LABEL: @or_sel_const2_eq1(
; CHECK: f:
; CHECK-NEXT: %r = call i1 @jeandle.check_instanceof
; CHECK-NEXT: ret i1 %r
; CHECK-LABEL: @sext_sle0(
; CHECK: t:
; CHECK-NEXT: %r = call i1 @jeandle.check_instanceof
; CHECK-NEXT: ret i1 %r
; CHECK-LABEL: @sext_ne0(
; CHECK: t:
; CHECK-NEXT: ret i1 true
; CHECK: f:
; CHECK-NEXT: ret i1 false
; CHECK-LABEL: @xor_i8_const(
; CHECK: t:
; CHECK-NEXT: ret i1 false
; CHECK: f:
; CHECK-NEXT: ret i1 true
; CHECK-LABEL: @or_i8_const2(
; CHECK: t:
; CHECK-NEXT: %r = call i1 @jeandle.check_instanceof
; CHECK: f:
; CHECK-NEXT: %r2 = call i1 @jeandle.check_instanceof
; CHECK-LABEL: @sub_const_not(
; CHECK: t:
; CHECK-NEXT: ret i1 true
; CHECK: f:
; CHECK-NEXT: ret i1 false

!java-method-compilation = !{}
