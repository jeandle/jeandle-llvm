; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; A loop-local allocation (created and consumed in the body every iteration)
; coexists with a loop-carried virtual (allocated before the loop, field
; carried across the back-edge). Pins non-interference: the loop-local
; alloc must NOT appear in the header merged state B (it never crosses the
; back-edge), so it must not perturb convergence of the carried virtual.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @use(i32)
declare i32 @__gxx_personality_v0(...)

define void @test_local_coexist_carried(i32 %n) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 40201 to ptr), i32 16, i1 false)
       to label %prep unwind label %u
prep:
  %s = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  store atomic i32 1, ptr addrspace(1) %s unordered, align 4
  br label %loop
loop:
  %i = phi i32 [ 0, %prep ], [ %i1, %st ]
  %c = icmp slt i32 %i, %n
  br i1 %c, label %body, label %exit
body:
  ; loop-local allocation
  %p = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 40202 to ptr), i32 16, i1 false)
       to label %st unwind label %u
st:
  %t = getelementptr inbounds i8, ptr addrspace(1) %p, i64 8
  store atomic i32 9, ptr addrspace(1) %t unordered, align 4
  %w = load atomic i32, ptr addrspace(1) %t unordered, align 4
  call void @use(i32 %w)
  ; carried field
  store atomic i32 %i, ptr addrspace(1) %s unordered, align 4
  %v = load atomic i32, ptr addrspace(1) %s unordered, align 4
  call void @use(i32 %v)
  %i1 = add i32 %i, 1
  br label %loop
exit:
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; Both allocations eliminated; loop-local folds to constant 9, carried folds to %i.
; CHECK-LABEL: define void @test_local_coexist_carried
; CHECK-NOT: jeandle.new_instance
; CHECK-NOT: store atomic
; CHECK-NOT: load atomic
; CHECK: call void @use(i32 9)
; CHECK: call void @use(i32 %i)

!java-method-compilation = !{}
