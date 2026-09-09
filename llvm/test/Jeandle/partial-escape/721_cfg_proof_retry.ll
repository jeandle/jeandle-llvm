; RUN: opt -S -verify-each \
; RUN:   -passes="require<partial-escape-analysis>,partial-escape-transform" \
; RUN:   -jeandle-vm-callback-log=%S/Inputs/231_value_based_check_value_based.cblog \
; RUN:   %s | FileCheck %s
; RUN: opt -disable-output -verify-each \
; RUN:   -passes="require<partial-escape-analysis>" -jeandle-trace-pea \
; RUN:   -jeandle-dump-pea-stats \
; RUN:   -jeandle-vm-callback-log=%S/Inputs/231_value_based_check_value_based.cblog \
; RUN:   %s 2>&1 | FileCheck %s --check-prefix=ATTEMPT \
; RUN:     --implicit-check-not='PEA stats @cfg_proof_retry: NeverEscapes=1 PartiallyEscapes=0 AlwaysEscapes=1'

; %is.null initially folds to false while %o is virtual. Later in the same
; attempt, the supported value-based-class check makes %o ineligible so commit
; drops the replacement that justified killing the edge. The analyzer must
; discard that attempt, suppress this stable CFG proof, and retry from untouched
; IR. A second virtual is used only by the provisionally dead arm: skipping
; that arm would eliminate the second allocation and leave @escape(poison).
; The winning plan retains both allocations, the original condition, and paths.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare hotspotcc i1
    @jeandle.check_if_value_based(ptr addrspace(1))
declare void @observe(i32)
declare void @observe_check(i1)
declare void @escape(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @cfg_proof_retry()
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 7777 to ptr), i32 16, i1 false)
      to label %second.alloc unwind label %alloc.unwind

second.alloc:
  %path.object = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 7777 to ptr), i32 16, i1 false)
      to label %dispatch unwind label %alloc.unwind

dispatch:
  %is.null = icmp eq ptr addrspace(1) %o, null
  br i1 %is.null, label %null.path, label %nonnull.path

null.path:
  call void @escape(ptr addrspace(1) %path.object)
  call void @observe(i32 81)
  br label %merge

nonnull.path:
  call void @observe(i32 82)
  br label %merge

merge:
  %is.value.based = call hotspotcc i1
      @jeandle.check_if_value_based(ptr addrspace(1) %o)
  call void @observe_check(i1 %is.value.based)
  ret void

alloc.unwind:
  %ex = landingpad i64 cleanup
  resume i64 %ex
}

; CHECK-LABEL: define void @cfg_proof_retry()
; CHECK: %[[O:[A-Za-z0-9._]+]] = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 7777 to ptr), i32 16, i1 false)
; CHECK: %[[PATHOBJ:[A-Za-z0-9._]+]] = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 7777 to ptr), i32 16, i1 false)
; CHECK: %[[ISNULL:[A-Za-z0-9._]+]] = icmp eq ptr addrspace(1) %[[O]], null
; CHECK: br i1 %[[ISNULL]], label %null.path, label %nonnull.path
; CHECK: null.path:
; CHECK: call void @escape(ptr addrspace(1) %[[PATHOBJ]])
; CHECK: call void @observe(i32 81)
; CHECK: nonnull.path:
; CHECK: call void @observe(i32 82)
; CHECK: merge:
; CHECK: call hotspotcc i1 @jeandle.check_if_value_based(ptr addrspace(1) %[[O]])
; CHECK: alloc.unwind:
; CHECK-NOT: poison

; A discarded attempt must publish neither its classification line nor its
; provisional effects. The winning conservative attempt keeps %o real and
; partially materializes only %path.object.
; ATTEMPT-NOT: PEA: EliminateAllocation function=@cfg_proof_retry [VO=1]
; ATTEMPT: PEA: EliminateAllocation function=@cfg_proof_retry [VO=1]
; ATTEMPT-NOT: PEA: EliminateAllocation function=@cfg_proof_retry [VO=1]
; ATTEMPT: PEA: Materialize function=@cfg_proof_retry [VO=1] block=%null.path
; ATTEMPT-NOT: PEA: Materialize function=@cfg_proof_retry [VO=1] block=%null.path
; ATTEMPT: PEA: Materialize function=@cfg_proof_retry [VO=1] block=%nonnull.path
; ATTEMPT-NOT: PEA: EliminateAllocation function=@cfg_proof_retry [VO=1]
; ATTEMPT: PEA stats @cfg_proof_retry: NeverEscapes=0 PartiallyEscapes=1 AlwaysEscapes=1

!java-method-compilation = !{}
