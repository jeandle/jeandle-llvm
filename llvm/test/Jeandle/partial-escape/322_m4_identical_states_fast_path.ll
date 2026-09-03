; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; identicalExitData fast path. An if/else diamond whose two arms
; produce byte-identical BlockExitData (same Virtuals, same FieldStates,
; same LockCounts) skips the per-VO loop in mergeStates and inherits
; from preds[0] wholesale. End-to-end behaviour: alloc + store + load
; all eliminated.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @use(i32)
declare i32 @__gxx_personality_v0(...)

define void @test_identical_states(i1 %c)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %prep unwind label %u
prep:
  %s = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  store atomic i32 99, ptr addrspace(1) %s unordered, align 4
  br i1 %c, label %left, label %right
left:
  ; No mutation: BlockExits[left] is byte-identical to BlockExits[right]
  br label %merge
right:
  br label %merge
merge:
  %v = load atomic i32, ptr addrspace(1) %s unordered, align 4
  call void @use(i32 %v)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; All elided; load folds to 99.
; CHECK-LABEL: define void @test_identical_states
; CHECK-NOT: jeandle.new_instance
; CHECK-NOT: store atomic
; CHECK-NOT: load atomic
; CHECK: call void @use(i32 99)

!java-method-compilation = !{}
