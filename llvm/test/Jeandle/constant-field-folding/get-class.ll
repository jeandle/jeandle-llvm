; RUN: opt -S -passes="constant-field-folding" -jeandle-vm-callback-log=%S/Inputs/get-class.cblog %s 2>&1 | FileCheck %s

@oop_handle_Mirror_7 = external dso_local global ptr addrspace(1)
@oop_handle_Test_0 = external dso_local global ptr addrspace(1)
@oop_handle_Null_1 = external dso_local global ptr addrspace(1)

declare hotspotcc ptr addrspace(1) @jeandle.get_class(ptr addrspace(1))

; An exact, non-null receiver can use the Class mirror oop handle directly.
define hotspotcc ptr addrspace(1) @fold_exact(
    ptr addrspace(1) nonnull "java-klass"="123" "java-klass-exact" %obj)
    #0 gc "hotspotgc" {
entry:
  %mirror = call hotspotcc ptr addrspace(1)
      @jeandle.get_class(ptr addrspace(1) %obj)
  ret ptr addrspace(1) %mirror
}

; A constant oop receiver can be folded through its actual dynamic Klass even
; without Java type attributes on the receiver.
define hotspotcc ptr addrspace(1) @fold_constant_oop() #0 gc "hotspotgc" {
entry:
  %obj = load ptr addrspace(1), ptr @oop_handle_Test_0
  %mirror = call hotspotcc ptr addrspace(1)
      @jeandle.get_class(ptr addrspace(1) %obj)
  ret ptr addrspace(1) %mirror
}

; A constant null receiver must retain get_class for its NPE behavior.
define hotspotcc ptr addrspace(1) @keep_constant_null() #0 gc "hotspotgc" {
entry:
  %obj = load ptr addrspace(1), ptr @oop_handle_Null_1
  %mirror = call hotspotcc ptr addrspace(1)
      @jeandle.get_class(ptr addrspace(1) %obj)
  ret ptr addrspace(1) %mirror
}

; A declared-but-not-exact type may hold a subclass, so getClass remains.
define hotspotcc ptr addrspace(1) @keep_nonexact(
    ptr addrspace(1) nonnull "java-klass"="123" %obj)
    #0 gc "hotspotgc" {
entry:
  %mirror = call hotspotcc ptr addrspace(1)
      @jeandle.get_class(ptr addrspace(1) %obj)
  ret ptr addrspace(1) %mirror
}

; Exact type without a non-null proof must retain the call's NPE behavior.
define hotspotcc ptr addrspace(1) @keep_nullable(
    ptr addrspace(1) "java-klass"="123" "java-klass-exact" %obj)
    #0 gc "hotspotgc" {
entry:
  %mirror = call hotspotcc ptr addrspace(1)
      @jeandle.get_class(ptr addrspace(1) %obj)
  ret ptr addrspace(1) %mirror
}

; CHECK-LABEL: define hotspotcc ptr addrspace(1) @fold_exact
; CHECK-NOT: call hotspotcc ptr addrspace(1) @jeandle.get_class
; CHECK: load ptr addrspace(1), ptr @oop_handle_Mirror_7
; CHECK: ret ptr addrspace(1)

; CHECK-LABEL: define hotspotcc ptr addrspace(1) @fold_constant_oop()
; CHECK:       %obj = load ptr addrspace(1), ptr @oop_handle_Test_0
; CHECK:       load ptr addrspace(1), ptr @oop_handle_Mirror_7

; CHECK-LABEL: define hotspotcc ptr addrspace(1) @keep_constant_null()
; CHECK:       call hotspotcc ptr addrspace(1) @jeandle.get_class

; CHECK-LABEL: define hotspotcc ptr addrspace(1) @keep_nonexact
; CHECK: call hotspotcc ptr addrspace(1) @jeandle.get_class

; CHECK-LABEL: define hotspotcc ptr addrspace(1) @keep_nullable
; CHECK: call hotspotcc ptr addrspace(1) @jeandle.get_class

attributes #0 = { "java-method"="1" }

!java-method-compilation = !{}
