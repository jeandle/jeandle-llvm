; RUN: opt -S -verify-each -jeandle-java-type-stats -passes='function(copy-specialization,print<java-type-analysis>,jeandle-java-type-cache-boundary)' -jeandle-vm-callback-log=%S/Inputs/cache-reuse.cblog %s > %t.cached.ll 2> %t.cached.stats
; RUN: FileCheck %s --check-prefix=STATS < %t.cached.stats
; RUN: FileCheck %s --check-prefix=IR < %t.cached.ll
; RUN: opt -S -verify-each -jeandle-disable-java-type-cache -passes=copy-specialization -jeandle-vm-callback-log=%S/Inputs/cache-reuse.cblog %s > %t.uncached.ll
; RUN: diff %t.cached.ll %t.uncached.ll
; RUN: opt -S -verify-each -jeandle-java-type-stats -jeandle-verify-java-type-cache -passes='function(copy-specialization,print<java-type-analysis>)' -jeandle-vm-callback-log=%S/Inputs/cache-reuse.cblog %s > %t.verified.ll 2> %t.verified.stats
; RUN: diff %t.cached.ll %t.verified.ll
; RUN: FileCheck %s --check-prefix=VERIFY < %t.verified.stats

; CopyFacts for both sites are queried before either rewrite. The second
; same-block source query therefore hits Final, even though both sites later
; expand to the bulk helper. A changed pass discards JavaTypeAnalysis through
; FAM; its independent statistics remain available afterward.

@ArrayCopyLoadStoreMaxElem = constant i32 8
@heapOopSize = constant i32 4

declare void @jeandle.copy(ptr addrspace(1), i64, ptr addrspace(1), i64,
                          i64, ptr, ptr, i64, i64)
declare void @bulk_clone(ptr addrspace(1), ptr addrspace(1), i64)

define hotspotcc void @jeandle.clone_payload(
    ptr addrspace(1) %src, i64 %src_offset,
    ptr addrspace(1) %dest, i64 %dest_offset, i64 %length,
    i1 %is_instance) #2 {
  %from = getelementptr i8, ptr addrspace(1) %src, i64 %src_offset
  %to = getelementptr i8, ptr addrspace(1) %dest, i64 %dest_offset
  call void @bulk_clone(ptr addrspace(1) %from, ptr addrspace(1) %to,
                        i64 %length)
  ret void
}

define void @unknown_clone(ptr addrspace(1) %src,
                           ptr addrspace(1) %first,
                           ptr addrspace(1) %second) #0 {
entry:
  call void @jeandle.copy(ptr addrspace(1) %src, i64 8,
      ptr addrspace(1) %first, i64 8, i64 4,
      ptr null, ptr null, i64 32, i64 32) #1
  call void @jeandle.copy(ptr addrspace(1) %src, i64 8,
      ptr addrspace(1) %second, i64 8, i64 4,
      ptr null, ptr null, i64 32, i64 32) #1
  ret void
}

; STATS-LABEL: JavaTypeAnalysis for function: unknown_clone
; STATS:         queries: 2
; STATS:         final type hits: 1
; STATS:         final type misses: 1
; STATS:         invalidation requests: 0
; STATS: JavaTypeCacheBoundary function: unknown_clone existing_analysis=0 action=none
; VERIFY-LABEL: JavaTypeAnalysis for function: unknown_clone
; VERIFY:         queries: 2
; VERIFY:         verifications: 2
; IR-LABEL: define void @unknown_clone(
; IR-NOT: call void @jeandle.copy
; IR: call hotspotcc void @jeandle.clone_payload
; IR-NOT: call void @jeandle.copy
; IR: call hotspotcc void @jeandle.clone_payload
; IR-NOT: call void @jeandle.copy
; IR: ret void

define void @typed_clone(ptr addrspace(1) "java-klass"="43" %src,
                         ptr addrspace(1) %first,
                         ptr addrspace(1) %second) #0 {
entry:
  call void @jeandle.copy(ptr addrspace(1) %src, i64 8,
      ptr addrspace(1) %first, i64 8, i64 4,
      ptr null, ptr null, i64 32, i64 32) #1
  call void @jeandle.copy(ptr addrspace(1) %src, i64 8,
      ptr addrspace(1) %second, i64 8, i64 4,
      ptr null, ptr null, i64 32, i64 32) #1
  ret void
}

; STATS-LABEL: JavaTypeAnalysis for function: typed_clone
; STATS:         queries: 2
; STATS:         final type hits: 1
; STATS:         final type misses: 1
; STATS:         invalidation requests: 0
; STATS: JavaTypeCacheBoundary function: typed_clone existing_analysis=0 action=none
; VERIFY-LABEL: JavaTypeAnalysis for function: typed_clone
; VERIFY:         queries: 2
; VERIFY:         verifications: 2
; IR-LABEL: define void @typed_clone(
; IR-NOT: call void @jeandle.copy
; IR: call hotspotcc void @jeandle.clone_payload
; IR-NOT: call void @jeandle.copy
; IR: call hotspotcc void @jeandle.clone_payload
; IR-NOT: call void @jeandle.copy
; IR: ret void

attributes #0 = { "java-method"="0" }
attributes #1 = { "jeandle.copy.kind"="clone-instance" }
attributes #2 = { noinline nounwind "gc-leaf-function" "lower-phase"="1" }

!java-method-compilation = !{}
