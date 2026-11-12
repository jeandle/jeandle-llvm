; RUN: opt -S -jeandle-java-type-stats -jeandle-java-type-query-trace -passes="constant-field-folding,print<java-type-analysis>" -jeandle-vm-callback-log=%S/Inputs/cff-nonexact.cblog %s 2>&1 | FileCheck %s
;
; T03 non-exact path: the receiver class is known but not exact, so CFF must
; query getJavaType and then decline to fold. Two sites in one context block
; exercise a real query followed by a Final hit.

declare ptr @jeandle.load_klass(ptr addrspace(1))

define void @cff_nonexact(ptr addrspace(1) nonnull "java-klass"="123" %obj) #0 gc "hotspotgc" {
entry:
  %k0 = call ptr @jeandle.load_klass(ptr addrspace(1) %obj)
  %k1 = call ptr @jeandle.load_klass(ptr addrspace(1) %obj)
  ret void
}

; CHECK: JavaTypeQuery function: cff_nonexact ordinal: 1
; CHECK-SAME: final_hits: 0 final_misses: 1 base_insertions: 1
; CHECK: JavaTypeQuery function: cff_nonexact ordinal: 2
; CHECK-SAME: final_hits: 1 final_misses: 0 base_insertions: 0
; CHECK-LABEL: JavaTypeAnalysis for function: cff_nonexact
; CHECK:         queries: 2
; CHECK:         final type hits: 1
; CHECK:         final type misses: 1
; CHECK:         base insertions: 1
; CHECK:         invalidation requests: 0
; CHECK:         %k0 = call ptr @jeandle.load_klass
; CHECK:         %k1 = call ptr @jeandle.load_klass

attributes #0 = { "java-method"="0" }
!java-method-compilation = !{}
