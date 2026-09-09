; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Real loop fixpoint: an alloc lives in entry and is used inside a loop
; only via a field load (no escape, no field mutation). The loop
; fixpoint tracks the object through the back-edge — every iteration
; sees the same all-default field state, the first post-body B' equals
; the entry state B, and the alloc is FULLY ELIMINATED (no preheader
; materialization). The load default-folds to zero. The analyser
; recognises that the loop body never escapes the object and skips the
; preheader force-materialise drain. The load folds to zero on every
; iteration.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @use(i32)
declare i32 @__gxx_personality_v0(...)

define void @test_alloc_before_loop(i32 %n) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %prep unwind label %u
prep:
  br label %loop
loop:
  %i = phi i32 [ 0, %prep ], [ %i1, %body ]
  %c = icmp slt i32 %i, %n
  br i1 %c, label %body, label %exit
body:
  %s = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
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

; The new_instance is fully eliminated (no materialization invoke
; anywhere). The load folds to its default zero, so @use receives 0.
; CHECK-LABEL: define void @test_alloc_before_loop
; CHECK-NOT: jeandle.new_instance
; CHECK: call void @use(i32 0)

!java-method-compilation = !{}
