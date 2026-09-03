; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Nested loops. Inner loop allocates %inner that stays scoped to the
; inner loop (consumed only by a scalar @use). Outer loop's body has the
; inner loop nested inside it. Validates the recursive processLoop
; dispatch (innermost-first) and that snapshots are correctly captured
; at each loop level.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @use(i32)
declare i32 @__gxx_personality_v0(...)

define void @test_nested_loops(i32 %n, i32 %m) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  br label %outer
outer:
  %i = phi i32 [ 0, %entry ], [ %i1, %outer.next ]
  %oc = icmp slt i32 %i, %n
  br i1 %oc, label %inner, label %exit
inner:
  %j = phi i32 [ 0, %outer ], [ %j1, %inner.cont ]
  %ic = icmp slt i32 %j, %m
  br i1 %ic, label %inner.body, label %outer.next
inner.body:
  %ob = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
              ptr inttoptr (i64 5555 to ptr), i32 16, i1 false)
          to label %ib.cont unwind label %u
ib.cont:
  %s = getelementptr inbounds i8, ptr addrspace(1) %ob, i64 8
  store atomic i32 %j, ptr addrspace(1) %s unordered, align 4
  %v = load atomic i32, ptr addrspace(1) %s unordered, align 4
  call void @use(i32 %v)
  br label %inner.cont
inner.cont:
  %j1 = add i32 %j, 1
  br label %inner
outer.next:
  %i1 = add i32 %i, 1
  br label %outer
exit:
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; The inner-body alloc is fully eliminated; the store/load are gone.
; CHECK-LABEL: define void @test_nested_loops
; CHECK-NOT: jeandle.new_instance
; CHECK-NOT: store atomic
; CHECK-NOT: load atomic
; CHECK: call void @use(i32 %j)

!java-method-compilation = !{}
