; RUN: opt -S -verify-each -passes="constant-field-folding" -jeandle-vm-callback-log=%S/Inputs/load-klass-complete-loop.cblog %s | FileCheck %s
;
; The loop header is queried after all receiver inputs are present. A type
; that is exact on the entry edge cannot stand for a different backedge type.

declare ptr @jeandle.load_klass(ptr addrspace(1))

define ptr @mixed_loop(ptr addrspace(1) nonnull "java-klass"="1000" "java-klass-exact" %first,
                       ptr addrspace(1) nonnull "java-klass"="2000" "java-klass-exact" %second,
                       i1 %more) {
entry:
  br label %loop
loop:
  %receiver = phi ptr addrspace(1) [ %first, %entry ], [ %second, %loop ]
  %klass = call ptr @jeandle.load_klass(ptr addrspace(1) %receiver)
  br i1 %more, label %loop, label %exit
exit:
  ret ptr %klass
}

; CHECK-LABEL: define ptr @mixed_loop(
; CHECK: %receiver = phi ptr addrspace(1) [ %first, %entry ], [ %second, %loop ]
; CHECK-NEXT: %klass = call ptr @jeandle.load_klass(ptr addrspace(1) %receiver)
; CHECK: ret ptr %klass

define ptr @same_loop(ptr addrspace(1) nonnull "java-klass"="1000" "java-klass-exact" %first,
                      ptr addrspace(1) nonnull "java-klass"="1000" "java-klass-exact" %second,
                      i1 %more) {
entry:
  br label %loop
loop:
  %receiver = phi ptr addrspace(1) [ %first, %entry ], [ %second, %loop ]
  %klass = call ptr @jeandle.load_klass(ptr addrspace(1) %receiver)
  br i1 %more, label %loop, label %exit
exit:
  ret ptr %klass
}

; CHECK-LABEL: define ptr @same_loop(
; CHECK: %receiver = phi ptr addrspace(1)
; CHECK-NOT: call ptr @jeandle.load_klass
; CHECK: ret ptr inttoptr (i64 1000 to ptr)

!java-method-compilation = !{}
