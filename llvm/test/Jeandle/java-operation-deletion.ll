; RUN: opt -S -passes="java-operation-lower<phase=0>,java-operation-deletion" %s 2>&1 | FileCheck %s

; Verify JavaOperationDeletion:
;   - erases fully-lowered (user-empty) phase-0 JavaOps (gone0, gone1),
;   - strips them from @llvm.used and removes the now-empty @llvm.used global.

@llvm.used = appending global [1 x ptr] [ptr @gone0], section "llvm.metadata"

define hotspotcc i32 @root(ptr addrspace(1) %p) #0 gc "hotspotgc" {
entry:
  %a = call i32 @gone0(i32 1, ptr addrspace(1) %p)
  ret i32 %a
}

; gone0 is phase=0, called once by root. phase=0 lowering inlines it into root;
; it then has no callers (only @llvm.used). Deletion strips @llvm.used and erases.
define i32 @gone0(i32 %x, ptr addrspace(1) %p) #1 {
  ret i32 %x
}

; gone1 is phase=0 and calls gone0. phase=0 lowering transitively inlines gone0
; into gone1; gone1 itself has no callers. Deletion erases it.
define i32 @gone1(i32 %x, ptr addrspace(1) %p) #1 {
  %y = call i32 @gone0(i32 %x, ptr addrspace(1) %p)
  ret i32 %y
}

attributes #0 = { "noinline" }
attributes #1 = { "lower-phase"="0" "noinline" }

; CHECK: define hotspotcc i32 @root
; CHECK-NOT: @gone0
; CHECK-NOT: @gone1
; CHECK-NOT: @llvm.used = appending global
