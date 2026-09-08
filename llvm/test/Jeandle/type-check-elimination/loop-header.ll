; RUN: opt -S -passes="type-check-elimination" -jeandle-vm-callback-log=%S/Inputs/loop-header.cblog %s 2>&1 | FileCheck %s

; Loop/back-edge semantics of the edge-facts engine.
; f1: the entering edge proves check(22), so the query in the loop header
;     folds. The header has a back edge, so edge dominance does not hold; only
;     the back-edge-skipping edge join proves this.
; f2: the only check sits on the latch, below the query. The back edge is
;     skipped, so the header-top query must NOT fold (first arrival at the
;     header never traverses the latch edge).

declare i1 @jeandle.check_instanceof(ptr addrspace(0), ptr addrspace(1) nonnull)

define i1 @f1(ptr addrspace(1) "java-klass"="1" %obj, i1 %c) gc "hotspotgc" {
entry:
  %ce = call i1 @jeandle.check_instanceof(ptr addrspace(0) inttoptr (i64 22 to ptr addrspace(0)), ptr addrspace(1) nonnull %obj)
  br i1 %ce, label %header, label %fail

header:
  %r = call i1 @jeandle.check_instanceof(ptr addrspace(0) inttoptr (i64 22 to ptr addrspace(0)), ptr addrspace(1) nonnull %obj)
  br i1 %c, label %header, label %done

fail:
  ret i1 false

done:
  ret i1 %r
}

define i1 @f2(ptr addrspace(1) "java-klass"="1" %obj) gc "hotspotgc" {
entry:
  br label %header

header:
  %r = call i1 @jeandle.check_instanceof(ptr addrspace(0) inttoptr (i64 22 to ptr addrspace(0)), ptr addrspace(1) nonnull %obj)
  %cl = call i1 @jeandle.check_instanceof(ptr addrspace(0) inttoptr (i64 22 to ptr addrspace(0)), ptr addrspace(1) nonnull %obj)
  br i1 %cl, label %header, label %done

done:
  ret i1 %r
}

; f1: the entry check stays (nothing known at its own site); the header query
; folds to true.
; CHECK-LABEL: define i1 @f1(
; CHECK: entry:
; CHECK-NEXT:   %ce = call i1 @jeandle.check_instanceof
; CHECK: header:
; CHECK-NEXT:   br i1 %c, label %header, label %done
; CHECK: done:
; CHECK-NEXT:   ret i1 true

; f2: both checks stay — the latch edge must not sharpen the header.
; CHECK-LABEL: define i1 @f2(
; CHECK: header:
; CHECK-NEXT:   %r = call i1 @jeandle.check_instanceof
; CHECK-NEXT:   %cl = call i1 @jeandle.check_instanceof
; CHECK-NEXT:   br i1 %cl, label %header, label %done

!java-method-compilation = !{}
