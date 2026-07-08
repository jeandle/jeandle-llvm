; RUN: opt -S -passes="java-operation-lower<phase=0>,java-operation-deletion" %s 2>&1 | FileCheck %s

; This is just a test to verify JavaOperationDeletion can delete all unused JavaOps.
; In the real Jeandle pipeline, we run JavaOperationDeletion after the last JavaOperationLower,
; so it can delete all JavaOps.

; Verify JavaOperationDeletion:
;   - erases fully-lowered (user-empty) phase-0 JavaOps (gone0, gone1),
;   - strips them from @llvm.used and removes the now-empty @llvm.used global,
;   - leaves a JavaOp that still has a real caller (kept0, phase 1, not driven by
;     phase=0 lowering) in place.

@llvm.used = appending global [3 x ptr] [ptr @gone0, ptr @gone1, ptr @kept0], section "llvm.metadata"

define hotspotcc i32 @root(ptr addrspace(1) %p) #0 gc "hotspotgc" {
entry:
  %a = call i32 @gone0(i32 1, ptr addrspace(1) %p)
  %b = call i32 @kept0(i32 2, ptr addrspace(1) %p)
  ret i32 %b
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

; kept0 is phase=1, not driven by phase=0 lowering. root still calls it, so it has
; a real user. Deletion must leave it defined.
define i32 @kept0(i32 %x, ptr addrspace(1) %p) #2 {
  ret i32 %x
}

attributes #0 = { "noinline" }
attributes #1 = { "lower-phase"="0" "noinline" }
attributes #2 = { "lower-phase"="1" "noinline" }

; CHECK: define hotspotcc i32 @root
; CHECK-NOT: @gone0
; CHECK-NOT: @gone1
; CHECK: define i32 @kept0
; CHECK-NOT: @llvm.used = appending global
