; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Regression test: a nested virtual array referenced by a surviving
; materialization must never be classified NeverEscapes.
;
; An outer object allocated before a loop holds a reference field pointing at
; a virtual inner array. Inside the loop a pointer PHI merges the folded
; field load (a whole-object alias of the inner) with a real pointer, so the
; Case-A fallback materializes the inner at that predecessor — and the
; latch-carry validation then marks the inner ineligible because the incoming
; is a load that does not structurally strip to the allocation. A subsequent
; loop-fixpoint rollback restores the inner's eligibility, so without the
; commit-time replay-closure audit the inner ends NeverEscapes while the
; outer's preheader materialization still replays the inner's OrigAlloc into
; the field. The cfg-kill phase would RAUW the eliminated OrigAlloc to
; poison, turning the field replay into a poison store that canonicalization
; deletes; the runtime object then reads a null/default field.
;
; The audit must detect the dangling replay reference and rebuild with the
; inner kept real: the inner's new_array survives and the field store keeps
; referencing that real array — never poison.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32)
declare void @escape(ptr addrspace(1))
declare void @use(i32)
declare i32 @__gxx_personality_v0(...)

define void @test_nested_replay_closure(i32 %n, i1 %c, ptr addrspace(1) %real)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
           ptr inttoptr (i64 1111 to ptr), i32 24, i1 false)
       to label %prep unwind label %u
prep:
  %inner = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
               ptr inttoptr (i64 2222 to ptr), i32 1, i32 32, i32 24, i32 262144)
           to label %c0 unwind label %u
c0:
  %fw = getelementptr inbounds i8, ptr addrspace(1) %o, i64 16
  store atomic ptr addrspace(1) %inner, ptr addrspace(1) %fw unordered, align 8
  br label %loop
loop:
  %i = phi i32 [ 0, %c0 ], [ %i1, %latch ]
  %done = icmp slt i32 %i, %n
  br i1 %done, label %body, label %exit
body:
  br i1 %c, label %takefield, label %usereal
takefield:
  %fr = getelementptr inbounds i8, ptr addrspace(1) %o, i64 16
  %lv = load atomic ptr addrspace(1), ptr addrspace(1) %fr unordered, align 8
  br label %join
usereal:
  br label %join
join:
  %x = phi ptr addrspace(1) [ %lv, %takefield ], [ %real, %usereal ]
  call void @escape(ptr addrspace(1) %o)
  %i1 = add i32 %i, 1
  br label %latch
latch:
  br label %loop
exit:
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; The inner array's allocation must be retained (kept real), and the outer's
; field store must reference that real array — never a poisoned value.
; CHECK-LABEL: define void @test_nested_replay_closure
; CHECK-NOT: store atomic ptr addrspace(1) poison
; CHECK: invoke hotspotcc{{.*}}@jeandle.new_array(ptr inttoptr (i64 2222 to ptr)
; CHECK: store atomic ptr addrspace(1) %inner, ptr addrspace(1) %fw

!java-method-compilation = !{}
