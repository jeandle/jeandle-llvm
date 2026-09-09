; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Alloc-before-loop holding a nested virtual whose own primitive field is
; mutated inside the body. Outer object %o is allocated in entry; its
; reference field is left default (null). Inside the body we allocate
; %inner and store an i32 into %inner's primitive field via a
; load-then-store cycle on the outer's reference slot. The body otherwise
; consumes only loaded scalars; no pointer leaks.
;
; This exercises the recursive nested-virtual handling under the loop
; fixpoint. The convergence check must agree on (a) %o is virtual at the
; loop header, (b) %inner is body-local and is created/destroyed each
; iteration with the same ID (AllocSiteToVO).

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @use(i32)
declare i32 @__gxx_personality_v0(...)

define void @test_alloc_before_loop_nested(i32 %n) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 1111 to ptr), i32 16, i1 false)
       to label %prep unwind label %u
prep:
  br label %loop
loop:
  %i = phi i32 [ 0, %prep ], [ %i1, %bcont ]
  %c = icmp slt i32 %i, %n
  br i1 %c, label %body, label %exit
body:
  %inner = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
                  ptr inttoptr (i64 2222 to ptr), i32 16, i1 false)
            to label %bcont unwind label %u
bcont:
  %is = getelementptr inbounds i8, ptr addrspace(1) %inner, i64 8
  store atomic i32 %i, ptr addrspace(1) %is unordered, align 4
  %v = load atomic i32, ptr addrspace(1) %is unordered, align 4
  call void @use(i32 %v)
  %i1 = add i32 %i, 1
  br label %loop
exit:
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; Both the outer and inner allocations should be fully eliminated; the
; inner's store/load fold to %i.
; CHECK-LABEL: define void @test_alloc_before_loop_nested
; CHECK-NOT: jeandle.new_instance
; CHECK-NOT: store atomic
; CHECK-NOT: load atomic
; CHECK: call void @use(i32 %i)

!java-method-compilation = !{}
