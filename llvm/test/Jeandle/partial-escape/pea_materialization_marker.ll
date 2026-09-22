; RUN: opt -S -verify-each -passes='always-inline,function(early-cse,instcombine,gvn,adce,simplifycfg)' %s | FileCheck %s --check-prefix=OPT
; RUN: opt -S -verify-each -passes='function(gvn)' %s | FileCheck %s --check-prefix=MEMORY
; RUN: opt -S -verify-each -passes='function(post-pea-cleanup,post-pea-cleanup)' %s | FileCheck %s --check-prefix=CLEAN --implicit-check-not='jeandle.pea.materialize'
; RUN: opt -S -verify-each --jeandle --jeandle-inline=off --jeandle-pea=false %s | FileCheck %s --check-prefix=CLEAN --implicit-check-not='jeandle.pea.materialize'
; RUN: opt -S -verify-each --jeandle --jeandle-inline=off --jeandle-pea-iterations=0 %s | FileCheck %s --check-prefix=CLEAN --implicit-check-not='jeandle.pea.materialize'

; A call-site memory attribute overrides unknown-bundle heap effects. Ordinary
; LLVM passes can forward heap loads while preserving marker operand identities.
; The existing Jeandle pipeline cleans up even when PEA does not run.

declare void @llvm.sideeffect()
declare void @jeandle.ensure_materialized_for_stack_walk(ptr addrspace(1))
attributes #0 = { memory(inaccessiblemem: readwrite) }

define internal void @boundary(ptr addrspace(1) %src, ptr addrspace(1) %dst) alwaysinline {
  call void @llvm.sideeffect() #0 [ "jeandle.pea.materialize"(ptr addrspace(1) %src, ptr addrspace(1) %dst) ]
  ret void
}

define void @inline_twice(ptr addrspace(1) %a, ptr addrspace(1) %b,
                         ptr addrspace(1) %c, ptr addrspace(1) %d) {
  call void @boundary(ptr addrspace(1) %a, ptr addrspace(1) %b)
  call void @boundary(ptr addrspace(1) %c, ptr addrspace(1) %d)
  ret void
}

; OPT-LABEL: define void @inline_twice(
; OPT: call void @llvm.sideeffect(){{.*}}[ "jeandle.pea.materialize"(ptr addrspace(1) %a, ptr addrspace(1) %b) ]
; OPT-NEXT: call void @llvm.sideeffect(){{.*}}[ "jeandle.pea.materialize"(ptr addrspace(1) %c, ptr addrspace(1) %d) ]
; OPT-NEXT: ret void
; CLEAN-LABEL: define void @inline_twice(
; CLEAN: ret void

define i32 @heap_forwarding(ptr addrspace(1) %src, ptr addrspace(1) %dst, i32 %value) {
  store i32 %value, ptr addrspace(1) %src, align 4
  call void @llvm.sideeffect() #0 [ "jeandle.pea.materialize"(ptr addrspace(1) %src, ptr addrspace(1) %dst) ]
  %loaded = load i32, ptr addrspace(1) %src, align 4
  ret i32 %loaded
}

; OPT-LABEL: define i32 @heap_forwarding(
; OPT: store i32 %value, ptr addrspace(1) %src, align 4
; OPT-NEXT: call void @llvm.sideeffect(){{.*}}[ "jeandle.pea.materialize"(ptr addrspace(1) %src, ptr addrspace(1) %dst) ]
; OPT-NEXT: ret i32 %value

; Run GVN on its own: EarlyCSE skips sideeffect irrespective of bundle memory
; effects, so its load forwarding cannot prove that the call-site attribute is
; effective. The otherwise-identical call below has the default unknown-bundle
; heap clobber and must prevent forwarding.
; MEMORY-LABEL: define i32 @heap_forwarding(
; MEMORY: store i32 %value,
; MEMORY: call void @llvm.sideeffect()
; MEMORY-NOT: load i32
; MEMORY: ret i32 %value

define i32 @heap_forwarding_without_override(ptr addrspace(1) %src, ptr addrspace(1) %dst, i32 %value) {
  store i32 %value, ptr addrspace(1) %src, align 4
  call void @llvm.sideeffect() [ "jeandle.pea.materialize"(ptr addrspace(1) %src, ptr addrspace(1) %dst) ]
  %loaded = load i32, ptr addrspace(1) %src, align 4
  ret i32 %loaded
}

; MEMORY-LABEL: define i32 @heap_forwarding_without_override(
; MEMORY: store i32 %value,
; MEMORY: call void @llvm.sideeffect()
; MEMORY-NEXT: %loaded = load i32, ptr addrspace(1) %src, align 4
; MEMORY-NEXT: ret i32 %loaded

define void @preserve_sideeffect(ptr addrspace(1) %src, ptr addrspace(1) %dst) {
  call void @llvm.sideeffect()
  call void @llvm.sideeffect() #0 [ "jeandle.pea.materialize"(ptr addrspace(1) %src, ptr addrspace(1) %dst) ]
  ret void
}

; CLEAN-LABEL: define void @preserve_sideeffect(
; CLEAN: call void @llvm.sideeffect()
; CLEAN-NEXT: ret void

define void @stackwalk_and_string_markers(ptr addrspace(1) %src, ptr addrspace(1) %dst) {
  call void @jeandle.ensure_materialized_for_stack_walk(ptr addrspace(1) %src)
  call void @llvm.sideeffect() #0 [ "jeandle.pea.materialize"(ptr addrspace(1) %src, ptr addrspace(1) %dst) ]
  ret void
}

; CLEAN-LABEL: define void @stackwalk_and_string_markers(
; CLEAN-NOT: call
; CLEAN: ret void
