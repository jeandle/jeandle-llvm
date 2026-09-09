; RUN: opt -S -passes="type-check-elimination" -jeandle-vm-callback-log=%S/Inputs/instanceof-incompatible.cblog %s 2>&1 | FileCheck %s

; Test: object with exact klass 2 (String, final) is incompatible with klass 3 (Runnable, interface).
; String is not a subtype of Runnable, String is not an interface,
; and since String is exact, areKlassesIncompatible => true, so the check folds to false.

declare i1 @jeandle.check_instanceof(ptr addrspace(0), ptr addrspace(1) nonnull)
declare ptr addrspace(0) @jeandle.load_klass(ptr addrspace(1) nonnull)
declare i1 @jeandle.check_exact_klass(ptr addrspace(0), ptr addrspace(0))

@glob = external addrspace(1) global ptr addrspace(1)

define i1 @test() gc "hotspotgc" {
entry:
  %obj = load ptr addrspace(1), ptr addrspace(1) @glob, !java-klass !0, !java-klass-exact !1
  %result = call i1 @jeandle.check_instanceof(
    ptr addrspace(0) inttoptr (i64 3 to ptr),
    ptr addrspace(1) nonnull %obj)
  ret i1 %result
}

; Profile receiver classes are exact even when the class is not effectively
; final. The equal edge therefore provides enough information to fold an
; incompatible type check to false.
define i1 @test_exact_klass_guard(ptr addrspace(1) %obj) gc "hotspotgc" {
entry:
  %actual_klass = call ptr addrspace(0) @jeandle.load_klass(
      ptr addrspace(1) nonnull %obj)
  %matches = call i1 @jeandle.check_exact_klass(
      ptr addrspace(0) inttoptr (i64 2 to ptr addrspace(0)),
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

!0 = !{i64 2}
!1 = !{}

; CHECK-LABEL: define i1 @test()
; CHECK: ret i1 false
; CHECK-LABEL: define i1 @test_exact_klass_guard
; CHECK-LABEL: hit:
; CHECK-NEXT: ret i1 false

!java-method-compilation = !{}
