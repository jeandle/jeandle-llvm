; RUN: opt -S -passes="recover-type-info" -jeandle-vm-callback-log=%S/Inputs/recover-null-arm-vacuous.cblog %s 2>&1 | FileCheck %s

; JavaType describes a value only when it is a non-null oop, and its PHI/select
; handling skips literal null and poison arms as vacuous under that contract.
; The lattice must apply the same rule: a lazy-initialization merge keeps the
; typed arm's klass instead of dropping to Bottom. An undef arm is NOT skipped
; — it can materialize an arbitrary oop when reached.

define void @phi_test(ptr addrspace(1) "java-klass"="5" %obj, i1 %c) #0 gc "hotspotgc" {
entry:
  br i1 %c, label %init, label %join
init:
  %addr = getelementptr i8, ptr addrspace(1) %obj, i64 16
  %loaded = load ptr addrspace(1), ptr addrspace(1) %addr
  br label %join
join:
  %p = phi ptr addrspace(1) [ null, %entry ], [ %loaded, %init ]
  %addr2 = getelementptr i8, ptr addrspace(1) %p, i64 16
  %v = load ptr addrspace(1), ptr addrspace(1) %addr2
  ret void
}

define void @select_test(ptr addrspace(1) "java-klass"="5" %obj, i1 %c) #0 gc "hotspotgc" {
entry:
  %addr = getelementptr i8, ptr addrspace(1) %obj, i64 16
  %loaded = load ptr addrspace(1), ptr addrspace(1) %addr
  %p = select i1 %c, ptr addrspace(1) %loaded, ptr addrspace(1) null
  %addr2 = getelementptr i8, ptr addrspace(1) %p, i64 16
  %v1 = load ptr addrspace(1), ptr addrspace(1) %addr2
  ret void
}

define void @undef_arm_stays_unknown(ptr addrspace(1) "java-klass"="5" %obj, i1 %c) #0 gc "hotspotgc" {
entry:
  br i1 %c, label %init, label %join
init:
  %addr = getelementptr i8, ptr addrspace(1) %obj, i64 16
  %loaded = load ptr addrspace(1), ptr addrspace(1) %addr
  br label %join
join:
  %p = phi ptr addrspace(1) [ undef, %entry ], [ %loaded, %init ]
  %addr2 = getelementptr i8, ptr addrspace(1) %p, i64 16
  %v2 = load ptr addrspace(1), ptr addrspace(1) %addr2
  ret void
}

; CHECK: %v = load ptr addrspace(1), ptr addrspace(1) %addr2
; CHECK: , !java-klass ![[K:[0-9]+]]
; The select's null arm is vacuous the same way.
; CHECK: %v1 = load ptr addrspace(1), ptr addrspace(1) %addr2
; CHECK: , !java-klass ![[K]]
; An undef arm can materialize an arbitrary oop — that arm's chained load
; stays untyped (the init-block load above it is legitimately typed).
; CHECK-NOT: %v2{{.*}}!java-klass
; CHECK: ![[K]] = !{i64 9}

attributes #0 = { "java-method"="0" }

!java-method-compilation = !{}
