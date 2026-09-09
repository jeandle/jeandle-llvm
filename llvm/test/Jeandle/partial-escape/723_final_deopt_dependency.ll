; RUN: opt -S -verify-each \
; RUN:   -passes="require<partial-escape-analysis>,partial-escape-transform" \
; RUN:   -jeandle-vm-callback-log=%S/Inputs/231_value_based_check_value_based.cblog \
; RUN:   %s | FileCheck %s
; RUN: opt -disable-output \
; RUN:   -passes="require<partial-escape-analysis>" -jeandle-trace-pea \
; RUN:   -jeandle-dump-pea-stats \
; RUN:   -jeandle-vm-callback-log=%S/Inputs/231_value_based_check_value_based.cblog \
; RUN:   %s 2>&1 | FileCheck %s --check-prefix=ATTEMPT \
; RUN:     --implicit-check-not='PEA stats @final_deopt_dependency: NeverEscapes=1 PartiallyEscapes=0 AlwaysEscapes=1' \
; RUN:     --implicit-check-not='PEA stats @final_deopt_ssa_shapes: NeverEscapes=1 PartiallyEscapes=0 AlwaysEscapes=1'

; The equality initially folds to false and hides both allocation operands
; behind a scalar alias.  The later value-based check makes %a ineligible, so
; commit drops the equality replacement owned by %a.  The surviving deopt root
; therefore depends on %b, whose allocation must not be eliminated.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare hotspotcc i1
    @jeandle.check_if_value_based(ptr addrspace(1))
declare void @safepoint()
declare void @observe(i1)
declare ptr addrspace(1)
    @llvm.launder.invariant.group.p1(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

@deopt.constant.anchor = external addrspace(1) global i8

define void @final_deopt_dependency()
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 7777 to ptr), i32 16, i1 false)
      to label %alloc.b unwind label %unwind

alloc.b:
  %b = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 7777 to ptr), i32 16, i1 false)
      to label %body unwind label %unwind

body:
  %same = icmp eq ptr addrspace(1) %a, %b
  call void @safepoint()
      [ "deopt"(i32 99, i32 99, i64 10, i1 %same) ]
  %is.value.based = call hotspotcc i1
      @jeandle.check_if_value_based(ptr addrspace(1) %a)
  call void @observe(i1 %is.value.based)
  ret void

unwind:
  %ex = landingpad i64 cleanup
  resume i64 %ex
}

; CHECK-LABEL: define void @final_deopt_dependency()
; CHECK-COUNT-2: invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK: %[[SAME:[A-Za-z0-9._]+]] = icmp eq ptr addrspace(1) %a, %b
; CHECK: call void @safepoint()
; CHECK-SAME: [ "deopt"(i32 99, i32 99, i64 10, i1 %[[SAME]]) ]
; CHECK-NOT: poison

; No classification, trace, or statistic from the failed attempt may be
; published. In the winner only %a is analyzed. Although %b is retained by
; site suppression and has no tracked ObjectID, it remains a distinct fresh
; allocation site, so the target-relative distinctness proof keeps the
; contradiction fold.
; ATTEMPT-NOT: PEA: EliminateAllocation function=@final_deopt_dependency [VO=1]
; ATTEMPT: ;; PEA stats @final_deopt_dependency: NeverEscapes=0 PartiallyEscapes=0 AlwaysEscapes=1

define void @final_deopt_ssa_shapes(i1 %pick)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 7777 to ptr), i32 16, i1 false)
      to label %alloc.b unwind label %unwind

alloc.b:
  %b = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 7777 to ptr), i32 16, i1 false)
      to label %body unwind label %unwind

body:
  %same = icmp eq ptr addrspace(1) %a, %b
  %frozen = freeze i1 %same
  %selected = select i1 %pick, i1 %frozen, i1 false
  br i1 %pick, label %left, label %right

left:
  br label %merge

right:
  br label %merge

merge:
  %merged = phi i1 [ %frozen, %left ], [ %selected, %right ]
  %wide = zext i1 %merged to i64
  %as.pointer = inttoptr i64 %wide to ptr addrspace(1)
  %zero.gep =
      getelementptr i8, ptr addrspace(1) %as.pointer, i64 0
  %as.integer = ptrtoint ptr addrspace(1) %zero.gep to i64
  %roundtrip = inttoptr i64 %as.integer to ptr addrspace(1)
  %as.zero = addrspacecast ptr addrspace(1) %roundtrip to ptr
  %as.heap = addrspacecast ptr %as.zero to ptr addrspace(1)
  %identity = call ptr addrspace(1)
      @llvm.launder.invariant.group.p1(ptr addrspace(1) %as.heap)
  %aggregate = insertvalue { ptr addrspace(1), i32 } poison,
      ptr addrspace(1) %identity, 0
  %aggregate.value =
      extractvalue { ptr addrspace(1), i32 } %aggregate, 0
  %vector.0 = insertelement <2 x ptr addrspace(1)> poison,
      ptr addrspace(1) %aggregate.value, i64 0
  %vector.1 = insertelement <2 x ptr addrspace(1)> %vector.0,
      ptr addrspace(1) null, i64 1
  %shuffled = shufflevector <2 x ptr addrspace(1)> %vector.1,
      <2 x ptr addrspace(1)> poison, <2 x i32> <i32 0, i32 1>
  %lane = extractelement <2 x ptr addrspace(1)> %shuffled, i64 0
  %with.constant.expr = select i1 %pick, ptr addrspace(1) %lane,
      ptr addrspace(1) getelementptr (
          i8, ptr addrspace(1) @deopt.constant.anchor, i64 0)
  call void @safepoint()
      [ "deopt"(i32 99, i32 99, i64 12,
                  ptr addrspace(1) %with.constant.expr) ]
  %is.value.based = call hotspotcc i1
      @jeandle.check_if_value_based(ptr addrspace(1) %a)
  call void @observe(i1 %is.value.based)
  ret void

unwind:
  %ex = landingpad i64 cleanup
  resume i64 %ex
}

; CHECK-LABEL: define void @final_deopt_ssa_shapes(
; CHECK-COUNT-2: invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK: %same = icmp eq ptr addrspace(1) %a, %b
; CHECK: %frozen = freeze i1 %same
; CHECK: %merged = phi i1
; CHECK: %roundtrip = inttoptr i64 %as.integer to ptr addrspace(1)
; CHECK: %identity = call ptr addrspace(1) @llvm.launder.invariant.group.p1
; CHECK: %aggregate = insertvalue
; CHECK: %shuffled = shufflevector
; CHECK: %with.constant.expr = select i1 %pick
; CHECK: call void @safepoint()
; CHECK-SAME: ptr addrspace(1) %with.constant.expr
; CHECK-NOT: poison

; ATTEMPT-NOT: PEA: EliminateAllocation function=@final_deopt_ssa_shapes [VO=1]
; ATTEMPT: ;; PEA stats @final_deopt_ssa_shapes: NeverEscapes=0 PartiallyEscapes=0 AlwaysEscapes=1

!java-method-compilation = !{}
