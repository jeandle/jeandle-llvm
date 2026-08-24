; RUN: opt -S -passes="constant-field-folding" -jeandle-vm-callback-log=%S/Inputs/load-klass.cblog %s 2>&1 | FileCheck %s

@oop_handle_Test_0 = external dso_local global ptr addrspace(1)
@oop_handle_Test_1 = external dso_local global ptr addrspace(1)

declare hotspotcc ptr @jeandle.load_klass(ptr addrspace(1))

define hotspotcc ptr @fold_direct() #0 gc "hotspotgc" {
entry:
  %obj = load ptr addrspace(1), ptr @oop_handle_Test_0
  %klass = call hotspotcc ptr @jeandle.load_klass(ptr addrspace(1) %obj)
  ret ptr %klass
}

; CHECK-LABEL: define hotspotcc ptr @fold_direct()
; CHECK:       entry:
; CHECK-NEXT:    %obj = load ptr addrspace(1), ptr @oop_handle_Test_0
; CHECK-NEXT:    ret ptr inttoptr (i64 123456 to ptr)

define hotspotcc ptr @fold_same_phi(i1 %cond) #0 gc "hotspotgc" {
entry:
  %obj = load ptr addrspace(1), ptr @oop_handle_Test_0
  br i1 %cond, label %left, label %right

left:
  br label %merge

right:
  br label %merge

merge:
  %merged = phi ptr addrspace(1) [ %obj, %left ], [ %obj, %right ]
  %klass = call hotspotcc ptr @jeandle.load_klass(ptr addrspace(1) %merged)
  ret ptr %klass
}

; CHECK-LABEL: define hotspotcc ptr @fold_same_phi(
; CHECK:       merge:
; CHECK-NEXT:    %merged = phi ptr addrspace(1)
; CHECK-NEXT:    ret ptr inttoptr (i64 123456 to ptr)

define hotspotcc ptr @keep_dynamic(ptr addrspace(1) %obj) #0 gc "hotspotgc" {
entry:
  %klass = call hotspotcc ptr @jeandle.load_klass(ptr addrspace(1) %obj)
  ret ptr %klass
}

; CHECK-LABEL: define hotspotcc ptr @keep_dynamic(
; CHECK:         %klass = call hotspotcc ptr @jeandle.load_klass(ptr addrspace(1) %obj)
; CHECK-NEXT:    ret ptr %klass

define hotspotcc ptr @keep_unavailable() #0 gc "hotspotgc" {
entry:
  %obj = load ptr addrspace(1), ptr @oop_handle_Test_1
  %klass = call hotspotcc ptr @jeandle.load_klass(ptr addrspace(1) %obj)
  ret ptr %klass
}

; CHECK-LABEL: define hotspotcc ptr @keep_unavailable()
; CHECK:         %klass = call hotspotcc ptr @jeandle.load_klass(ptr addrspace(1) %obj)
; CHECK-NEXT:    ret ptr %klass

define hotspotcc ptr @fold_exact_type(
    ptr addrspace(1) nonnull "java-klass"="123456"
      "java-klass-exact" %obj) #0 gc "hotspotgc" {
entry:
  %klass = call hotspotcc ptr @jeandle.load_klass(ptr addrspace(1) %obj)
  ret ptr %klass
}

define hotspotcc ptr @keep_nonexact_type(
    ptr addrspace(1) nonnull "java-klass"="123456" %obj)
    #0 gc "hotspotgc" {
entry:
  %klass = call hotspotcc ptr @jeandle.load_klass(ptr addrspace(1) %obj)
  ret ptr %klass
}

define hotspotcc ptr @keep_nullable_exact_type(
    ptr addrspace(1) "java-klass"="123456" "java-klass-exact" %obj)
    #0 gc "hotspotgc" {
entry:
  %klass = call hotspotcc ptr @jeandle.load_klass(ptr addrspace(1) %obj)
  ret ptr %klass
}

; CHECK-LABEL: define hotspotcc ptr @fold_exact_type(
; CHECK:       ret ptr inttoptr (i64 123456 to ptr)

; CHECK-LABEL: define hotspotcc ptr @keep_nonexact_type(
; CHECK:         %klass = call hotspotcc ptr @jeandle.load_klass(ptr addrspace(1) %obj)

; CHECK-LABEL: define hotspotcc ptr @keep_nullable_exact_type(
; CHECK:         %klass = call hotspotcc ptr @jeandle.load_klass(ptr addrspace(1) %obj)

attributes #0 = { "java-method"="1" }

!java-method-compilation = !{}
