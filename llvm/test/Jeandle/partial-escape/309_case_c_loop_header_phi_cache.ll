; RUN: opt -S -passes="loop-simplify,require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; A loop-header Case-C cache hit must rebuild FieldStates[Cached] on
; iter (N+1) — naively early-returning after re-aliasing the PHI to the
; cached ObjectID (and adding an empty ObjectState) would leave the
; synthetic VO functionally empty across iterations.
;
; Pattern: a loop whose header IS the Case-C merge block. The header
; receives two forward-edge incomings from a pre-loop diamond (each
; allocating a Point with field == 7) PLUS one back-edge incoming that
; replays the header PHI itself. The body LOAD of the merged Point's
; field must fold to 7 across the iterative fixpoint; without the
; rebuild the cache-hit on iter 1 leaves FieldStates[Cached] empty and
; the load resolves to "unknown", materializing the per-pred
; allocations.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @use(i32)
declare i32 @__gxx_personality_v0(...)

define void @test_case_c_loop_header_cache(i32 %n, i1 %c)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  br i1 %c, label %left, label %right
left:
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 22222 to ptr), i32 16, i1 false)
        to label %la unwind label %u
la:
  %sa = getelementptr inbounds i8, ptr addrspace(1) %a, i64 8
  store atomic i32 7, ptr addrspace(1) %sa unordered, align 4
  br label %loop
right:
  %b = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 22222 to ptr), i32 16, i1 false)
        to label %lb unwind label %u
lb:
  %sb = getelementptr inbounds i8, ptr addrspace(1) %b, i64 8
  store atomic i32 7, ptr addrspace(1) %sb unordered, align 4
  br label %loop
loop:
  %i = phi i32 [ 0, %la ], [ 0, %lb ], [ %i1, %body ]
  %p = phi ptr addrspace(1) [ %a, %la ], [ %b, %lb ], [ %p, %body ]
  %cc = icmp slt i32 %i, %n
  br i1 %cc, label %body, label %exit
body:
  %sl = getelementptr inbounds i8, ptr addrspace(1) %p, i64 8
  %vv = load atomic i32, ptr addrspace(1) %sl unordered, align 4
  call void @use(i32 %vv)
  %i1 = add i32 %i, 1
  br label %loop
exit:
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; The case-C VO synthesized at the loop header (%loop) carries field 8 == 7;
; the body LOAD folds across the fixpoint and reaches @use as a constant.
; CHECK-LABEL: define void @test_case_c_loop_header_cache
; CHECK-NOT: load atomic
; CHECK: call void @use(i32 7)

!java-method-compilation = !{}
