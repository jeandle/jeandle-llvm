; RUN: opt -disable-output -jeandle-java-type-stats -passes="type-check-elimination,print<java-type-analysis>,recover-type-info,print<java-type-analysis>" -jeandle-vm-callback-log=%S/Inputs/tce-recover.cblog %s 2>&1 | FileCheck %s --check-prefix=CROSS
; RUN: opt -disable-output -jeandle-java-type-stats -passes="type-check-elimination,print<java-type-analysis>,jeandle-java-type-cache-boundary,recover-type-info,print<java-type-analysis>" -jeandle-vm-callback-log=%S/Inputs/tce-recover.cblog %s 2>&1 | FileCheck %s --check-prefix=LOCAL
; RUN: opt -S -passes="type-check-elimination,recover-type-info" -jeandle-vm-callback-log=%S/Inputs/tce-recover.cblog %s 2>&1 | FileCheck %s --check-prefix=IR
;
; X01: TCE queries the unknown object twice without folding; RecoverTypeInfo
; then reads the same object from two loads in the same block. CROSS-PASS uses
; exactly the TCE-filled final result. PASS-LOCAL clears only the JavaType cache
; at the boundary, so the first downstream query must miss.

declare i1 @jeandle.check_instanceof(ptr, ptr addrspace(1) nonnull)

define void @tce_recover(ptr addrspace(1) nonnull %obj) #0 gc "hotspotgc" {
entry:
  %c0 = call i1 @jeandle.check_instanceof(ptr inttoptr (i64 9 to ptr), ptr addrspace(1) nonnull %obj)
  %c1 = call i1 @jeandle.check_instanceof(ptr inttoptr (i64 9 to ptr), ptr addrspace(1) nonnull %obj)
  %p0 = getelementptr i8, ptr addrspace(1) %obj, i64 16
  %l0 = load ptr addrspace(1), ptr addrspace(1) %p0, align 8
  %p1 = getelementptr i8, ptr addrspace(1) %obj, i64 24
  %l1 = load ptr addrspace(1), ptr addrspace(1) %p1, align 8
  ret void
}

; CROSS-LABEL: JavaTypeAnalysis for function: tce_recover
; CROSS:         queries: 2
; CROSS:         final type hits: 1
; CROSS:         final type misses: 1
; CROSS:         base insertions: 1
; CROSS:         current base entries: 1
; CROSS:         current final type entries: 1
; CROSS:         invalidation requests: 0
; CROSS-LABEL: JavaTypeAnalysis for function: tce_recover
; CROSS:         queries: 4
; CROSS:         final type hits: 3
; CROSS:         final type misses: 1
; CROSS:         base insertions: 1
; CROSS:         clears: 0
; CROSS:         invalidation requests: 0

; LOCAL-LABEL: JavaTypeAnalysis for function: tce_recover
; LOCAL:         queries: 2
; LOCAL:         final type hits: 1
; LOCAL:         final type misses: 1
; LOCAL:         base insertions: 1
; LOCAL:         JavaTypeCacheBoundary function: tce_recover existing_analysis=1 action=clear
; LOCAL-LABEL: JavaTypeAnalysis for function: tce_recover
; LOCAL:         queries: 4
; LOCAL:         final type hits: 2
; LOCAL:         final type misses: 2
; LOCAL:         base insertions: 2
; LOCAL:         clears: 1
; LOCAL:         invalidation requests: 1
; LOCAL:         base entries invalidated: 1
; LOCAL:         final type entries invalidated: 1

; The receiver has no java-klass attribute, so RecoverTypeInfo can query the
; loads but cannot emit useful field metadata. This run checks that the
; cross-pass cache reuse does not change the input semantics.
; IR:         %l0 = load ptr addrspace(1), ptr addrspace(1) %p0, align 8
; IR-NEXT:    %p1 = getelementptr
; IR-NEXT:    %l1 = load
; IR-NOT:     !java-klass

attributes #0 = { "java-method"="0" }
!java-method-compilation = !{}
