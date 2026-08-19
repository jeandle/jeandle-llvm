; RUN: opt -S -passes="constant-field-folding" -jeandle-vm-callback-log=%S/Inputs/get-class.cblog %s 2>&1 | FileCheck %s

@oop_handle_Mirror_7 = external dso_local global ptr addrspace(1)

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

; CHECK-LABEL: define hotspotcc ptr addrspace(1) @keep_nonexact
; CHECK: call hotspotcc ptr addrspace(1) @jeandle.get_class

; CHECK-LABEL: define hotspotcc ptr addrspace(1) @keep_nullable
; CHECK: call hotspotcc ptr addrspace(1) @jeandle.get_class

attributes #0 = { "java-method"="1" }

!java-method-compilation = !{}
