; RUN: opt -S -passes="type-check-elimination" -jeandle-vm-callback-log=%S/Inputs/instanceof-known-subtype.cblog %s 2>&1 | FileCheck %s
; RUN: opt -S -passes="java-operation-lower<phase=0>,function(type-check-elimination)" -jeandle-vm-callback-log=%S/Inputs/instanceof-known-subtype.cblog %s 2>&1 | FileCheck %s

; Test: object with known klass 5 (SubRunnable) is a subtype of klass 4 (MyRunnable).
; IsSubtype(5, 4) => true, so the check folds to true.

declare i1 @jeandle.check_instanceof(ptr addrspace(0), ptr addrspace(1) nonnull)
define ptr addrspace(0) @jeandle.load_klass(ptr addrspace(1) nonnull %oop) #0 {
  %actual = load atomic ptr addrspace(0), ptr addrspace(1) %oop unordered, align 8
  ret ptr addrspace(0) %actual
}

define i1 @jeandle.check_exact_klass(ptr addrspace(0) %expected, ptr addrspace(0) %actual) #0 {
  %matches = icmp eq ptr addrspace(0) %actual, %expected
  ret i1 %matches
}

@glob = external addrspace(1) global ptr addrspace(1)

define i1 @test() gc "hotspotgc" {
entry:
  %obj = load ptr addrspace(1), ptr addrspace(1) @glob, !java-klass !0
  %result = call i1 @jeandle.check_instanceof(
    ptr addrspace(0) inttoptr (i64 4 to ptr),
    ptr addrspace(1) nonnull %obj)
  ret i1 %result
}

; A profile guard compares the receiver's dynamic Klass with klass 5. On the
; equal edge, getJavaType should infer exact klass 5 without an oop wrapper.
define i1 @test_exact_klass_guard(ptr addrspace(1) %obj) gc "hotspotgc" {
entry:
  %actual_klass = call ptr addrspace(0) @jeandle.load_klass(
      ptr addrspace(1) nonnull %obj)
  %matches = call i1 @jeandle.check_exact_klass(
      ptr addrspace(0) inttoptr (i64 5 to ptr addrspace(0)),
      ptr addrspace(0) %actual_klass)
  br i1 %matches, label %hit, label %miss

hit:
  %result = call i1 @jeandle.check_instanceof(
    ptr addrspace(0) inttoptr (i64 4 to ptr addrspace(0)),
    ptr addrspace(1) nonnull %obj)
  ret i1 %result

miss:
  ret i1 false
}

; The exact-class intrinsic is symmetric: the loaded Klass may appear in the
; first argument after an IR rewrite. The hit path must still infer klass 5.
define i1 @test_exact_klass_guard_reversed(ptr addrspace(1) %obj) gc "hotspotgc" {
entry:
  %actual_klass = call ptr addrspace(0) @jeandle.load_klass(
      ptr addrspace(1) nonnull %obj)
  %matches = call i1 @jeandle.check_exact_klass(
      ptr addrspace(0) %actual_klass,
      ptr addrspace(0) inttoptr (i64 5 to ptr addrspace(0)))
  br i1 %matches, label %hit, label %miss

hit:
  %result = call i1 @jeandle.check_instanceof(
    ptr addrspace(0) inttoptr (i64 4 to ptr),
    ptr addrspace(1) nonnull %obj)
  ret i1 %result

miss:
  ret i1 false
}

; A bimorphic profile guard reaches the second target only after the first
; exact class comparison fails. The second equality edge must independently
; sharpen the receiver to klass 5.
define i1 @test_bimorphic_second_guard(ptr addrspace(1) %obj) gc "hotspotgc" {
entry:
  %actual_klass = call ptr addrspace(0) @jeandle.load_klass(
      ptr addrspace(1) nonnull %obj)
  %matches_first = call i1 @jeandle.check_exact_klass(
      ptr addrspace(0) inttoptr (i64 6 to ptr addrspace(0)),
      ptr addrspace(0) %actual_klass)
  br i1 %matches_first, label %first_hit, label %second_check

first_hit:
  ret i1 false

second_check:
  %matches_second = call i1 @jeandle.check_exact_klass(
      ptr addrspace(0) inttoptr (i64 5 to ptr addrspace(0)),
      ptr addrspace(0) %actual_klass)
  br i1 %matches_second, label %second_hit, label %miss

second_hit:
  %result = call i1 @jeandle.check_instanceof(
    ptr addrspace(0) inttoptr (i64 4 to ptr addrspace(0)),
    ptr addrspace(1) nonnull %obj)
  ret i1 %result

miss:
  ret i1 false
}

; A guard on another object's Klass must not sharpen the queried object.
define i1 @test_mismatched_guard_subject(ptr addrspace(1) %obj,
                                        ptr addrspace(1) %other) gc "hotspotgc" {
entry:
  %actual_klass = call ptr addrspace(0) @jeandle.load_klass(
      ptr addrspace(1) nonnull %other)
  %matches = call i1 @jeandle.check_exact_klass(
      ptr addrspace(0) inttoptr (i64 5 to ptr addrspace(0)),
      ptr addrspace(0) %actual_klass)
  br i1 %matches, label %hit, label %miss

hit:
  %result = call i1 @jeandle.check_instanceof(
    ptr addrspace(0) inttoptr (i64 4 to ptr addrspace(0)),
    ptr addrspace(1) nonnull %obj)
  ret i1 %result

miss:
  ret i1 false
}

; Intersecting a non-exact base type with an exact guard for the same Klass
; must preserve Exact=true. Klass 5 is a class that does not implement
; interface 3, so the hit-path instanceof can fold to false only when the
; exact constraint survives the final base/sharpened intersection.
define i1 @test_same_klass_exact_intersection(
    ptr addrspace(1) "java-klass"="5" %obj) gc "hotspotgc" {
entry:
  %actual_klass = call ptr addrspace(0) @jeandle.load_klass(
      ptr addrspace(1) nonnull %obj)
  %matches = call i1 @jeandle.check_exact_klass(
      ptr addrspace(0) inttoptr (i64 5 to ptr addrspace(0)),
      ptr addrspace(0) %actual_klass)
  br i1 %matches, label %hit, label %miss

hit:
  %result = call i1 @jeandle.check_instanceof(
      ptr addrspace(0) inttoptr (i64 3 to ptr addrspace(0)),
      ptr addrspace(1) nonnull %obj)
  ret i1 %result

miss:
  ret i1 true
}

; Dominator walking visits the inner exact guard before the outer instanceof
; guard. The later non-exact constraint for the same Klass must not downgrade
; the exact type already accumulated in Best.
define i1 @test_dominating_guard_preserves_exact(
    ptr addrspace(1) %obj) gc "hotspotgc" {
entry:
  %is_klass_5 = call i1 @jeandle.check_instanceof(
      ptr addrspace(0) inttoptr (i64 5 to ptr addrspace(0)),
      ptr addrspace(1) nonnull %obj)
  br i1 %is_klass_5, label %exact_check, label %miss

exact_check:
  %actual_klass = call ptr addrspace(0) @jeandle.load_klass(
      ptr addrspace(1) nonnull %obj)
  %matches = call i1 @jeandle.check_exact_klass(
      ptr addrspace(0) inttoptr (i64 5 to ptr addrspace(0)),
      ptr addrspace(0) %actual_klass)
  br i1 %matches, label %hit, label %miss

hit:
  %result = call i1 @jeandle.check_instanceof(
      ptr addrspace(0) inttoptr (i64 3 to ptr addrspace(0)),
      ptr addrspace(1) nonnull %obj)
  ret i1 %result

miss:
  ret i1 true
}

!0 = !{i64 5}

; CHECK-LABEL: define i1 @test()
; CHECK: ret i1 true
; CHECK-LABEL: define i1 @test_exact_klass_guard
; CHECK-LABEL: hit:
; CHECK-NEXT: ret i1 true
; CHECK-LABEL: define i1 @test_exact_klass_guard_reversed
; CHECK-LABEL: hit:
; CHECK-NEXT: ret i1 true
; CHECK-LABEL: define i1 @test_bimorphic_second_guard
; CHECK: %actual_klass = call ptr @jeandle.load_klass
; CHECK-NOT: call ptr @jeandle.load_klass
; CHECK-LABEL: second_hit:
; CHECK-NEXT: ret i1 true
; CHECK-LABEL: define i1 @test_mismatched_guard_subject
; CHECK-LABEL: hit:
; CHECK: call i1 @jeandle.check_instanceof
; CHECK-LABEL: define i1 @test_same_klass_exact_intersection
; CHECK-LABEL: hit:
; CHECK-NEXT: ret i1 false
; CHECK-LABEL: define i1 @test_dominating_guard_preserves_exact
; CHECK: %is_klass_5 = call i1 @jeandle.check_instanceof
; CHECK-LABEL: hit:
; CHECK-NEXT: ret i1 false

!java-method-compilation = !{}

attributes #0 = { noinline "lower-phase"="1" }
