; RUN: opt -S -passes="recover-type-info" -jeandle-vm-callback-log=%S/Inputs/recover-shared-base-cache.cblog %s 2>&1 | FileCheck %s
; RUN: opt -S -verify-each -jeandle-verify-java-type-cache -passes="recover-type-info" -jeandle-vm-callback-log=%S/Inputs/recover-shared-base-cache.cblog %s 2>&1 | FileCheck %s --check-prefix=VERIFY
; RUN: opt -disable-output -jeandle-java-type-stats -jeandle-verify-java-type-cache -passes="function(recover-type-info,print<java-type-analysis>)" -jeandle-vm-callback-log=%S/Inputs/recover-shared-base-cache.cblog %s 2>&1 | FileCheck %s --check-prefix=STATS
;
; RecoverTypeInfo queries Java types through the cached JavaTypeAnalysis engine.
; Both tracked loads below have the same query base (%obj) in the same block, so
; the second context-sensitive query is answered from the final-type cache: the
; first query inserts one base entry, the second adds none, and the pass needs
; no invalidation notification (it mutates no IR before its last query).

define void @shared_base(ptr addrspace(1) "java-klass"="5" %obj) #0 gc "hotspotgc" {
entry:
  %p0 = getelementptr i8, ptr addrspace(1) %obj, i64 16
  %l0 = load ptr addrspace(1), ptr addrspace(1) %p0, align 8
  %p1 = getelementptr i8, ptr addrspace(1) %obj, i64 24
  %l1 = load ptr addrspace(1), ptr addrspace(1) %p1, align 8
  ret void
}

; CHECK-LABEL: define void @shared_base(
; CHECK:         %l0 = load ptr addrspace(1), ptr addrspace(1) %p0, align 8, !java-klass ![[K0:[0-9]+]]
; CHECK:         %l1 = load ptr addrspace(1), ptr addrspace(1) %p1, align 8, !java-klass ![[K1:[0-9]+]]
; CHECK-DAG:     ![[K0]] = !{i64 7}
; CHECK-DAG:     ![[K1]] = !{i64 9}

; VERIFY-LABEL: define void @shared_base(
; VERIFY:         %l0 = load ptr addrspace(1), ptr addrspace(1) %p0, align 8, !java-klass
; VERIFY:         %l1 = load ptr addrspace(1), ptr addrspace(1) %p1, align 8, !java-klass

; STATS-LABEL: JavaTypeAnalysis for function: shared_base
; STATS:         queries: 2
; STATS:         final type hits: 1
; STATS:         final type misses: 1
; STATS:         base insertions: 1
; STATS:         clears: 0
; STATS:         invalidation requests: 0
; STATS:         bypasses: 0
; STATS:         verifications: 2

attributes #0 = { "java-method"="0" }

!java-method-compilation = !{}
