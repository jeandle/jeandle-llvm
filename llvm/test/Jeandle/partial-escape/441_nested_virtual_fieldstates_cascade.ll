; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" -jeandle-vm-callback-log=%S/Inputs/441_nested_virtual_fieldstates_cascade.cblog %s | FileCheck %s

; Nested-virtual poison via FieldStates VirtualRef.
;
; An Object[] array `arr` receives a CONSTANT-index store of a fresh virtual
; instance (arr[0] = inner0): processStore succeeds, records
; FieldStates[arr][16] = VirtualRef(inner0) and emits an EliminateStoreEffect
; for arr. A second store at a SYMBOLIC index `%i` (arr[i] = innerI) fails
; resolveAccess and materializes arr + innerI AT the symbolic store: the
; tracked arr[0] store is replayed onto arr's OrigAlloc (pea.matslot)
; immediately before it. If inner0 were left eligible it would be classified
; NeverEscapes (no surviving Materialize) -> Pass 2 RAUWs inner0.OrigAlloc
; to poison -> the replayed arr[0] store would write poison into the escaped
; array -> miscompile. Recursive materialization of the nested VirtualRef
; prevents this: inner0 is materialized first and its live pointer is
; replayed into the field.
;
; The commit-time live dependency graph is not what keeps inner0 real here:
; same-block materializeAt recursively materializes the VirtualRef
; (MatReason::Nested) at the escape point. For conservative fallback, commit
; reconstructs only live outer->inner dependencies from surviving/observed
; EliminateStore effects and VirtualRefStoreTargets; overwritten dead stores
; do not create persistent edges. This mirrors the recursive entry
; materialization while preserving Jeandle's analysis/transform split.

declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32)
declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

; Order A: constant store FIRST, symbolic store SECOND. The VirtualRef is in
; FieldStates[arr] before the symbolic store materializes arr, so the
; materialize point replays arr[0]=inner0 (pea.matslot) after recursively
; materializing inner0.
define void @test_nested_virtual_fieldstates_cascade(i64 %i) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %arr = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
            ptr inttoptr (i64 8888 to ptr), i32 10, i32 56, i32 16, i32 1048576)
         to label %n0 unwind label %u
n0:
  %inner0 = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 5555 to ptr), i32 24, i1 false)
           to label %n1 unwind label %u
n1:
  %innerI = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 5556 to ptr), i32 24, i1 false)
           to label %n2 unwind label %u
n2:
  %base = getelementptr inbounds i8, ptr addrspace(1) %arr, i32 16
  %slot0 = getelementptr inbounds ptr addrspace(1), ptr addrspace(1) %base, i64 0
  store atomic ptr addrspace(1) %inner0, ptr addrspace(1) %slot0 unordered, align 4
  %slotI = getelementptr inbounds ptr addrspace(1), ptr addrspace(1) %base, i64 %i
  store atomic ptr addrspace(1) %innerI, ptr addrspace(1) %slotI unordered, align 4
  call void @sink(ptr addrspace(1) %arr)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; Order B: symbolic store FIRST, constant store SECOND. arr (and innerI)
; materialize AT the symbolic store; when the constant-index store is
; processed arr is already materialized, so that store survives as a real
; store and inner0 is kept real as its stored value.
define void @test_reverse_order_fieldstates_cascade(i64 %i) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %arr = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
            ptr inttoptr (i64 8888 to ptr), i32 10, i32 56, i32 16, i32 1048576)
         to label %n0 unwind label %u
n0:
  %innerI = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 5555 to ptr), i32 24, i1 false)
           to label %n1 unwind label %u
n1:
  %inner0 = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 5556 to ptr), i32 24, i1 false)
           to label %n2 unwind label %u
n2:
  %base = getelementptr inbounds i8, ptr addrspace(1) %arr, i32 16
  %slotI = getelementptr inbounds ptr addrspace(1), ptr addrspace(1) %base, i64 %i
  store atomic ptr addrspace(1) %innerI, ptr addrspace(1) %slotI unordered, align 4
  %slot0 = getelementptr inbounds ptr addrspace(1), ptr addrspace(1) %base, i64 0
  store atomic ptr addrspace(1) %inner0, ptr addrspace(1) %slot0 unordered, align 4
  call void @sink(ptr addrspace(1) %arr)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @test_nested_virtual_fieldstates_cascade
; CHECK: jeandle.new_array
; CHECK-COUNT-2: invoke hotspotcc{{.*}}@jeandle.new_instance
; CHECK-NOT: poison

; CHECK-LABEL: define void @test_reverse_order_fieldstates_cascade
; CHECK: jeandle.new_array
; Both inner instances survive real; the arr[0] store writes the real inner0
; pointer (not poison), even though it was processed after arr had already
; materialized at the symbolic store.
; CHECK-COUNT-2: invoke hotspotcc{{.*}}@jeandle.new_instance
; CHECK-NOT: poison

!java-method-compilation = !{}
